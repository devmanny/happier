import { describe, expect, it, vi } from 'vitest';

import { AGENT_ROOM_MAX_AGENT_TURNS, agentRoomKvKey, sealAccountScopedBlobCiphertext, type AgentRoomV1 } from '@happier-dev/protocol';

import { createInMemoryAccountKv } from '@/api/kv/inMemoryAccountKv.testkit';

import { AgentRoomStore } from './agentRoomStore';
import { completeRoomTurn } from './completeRoomTurn';

const material = { type: 'dataKey', machineKey: new Uint8Array(32).fill(3) } as const;
const room: AgentRoomV1 = {
  v: 1, id: 'r1', title: 'App nueva', userName: 'Manny', lastSeq: 0, createdAt: 0, updatedAt: 0,
  members: [
    { agentId: 'a-mateo', name: 'Mateo', machineId: 'm1', directory: '/w1', wakeByAgents: true },
    { agentId: 'a-tomas', name: 'Tomás', machineId: 'm2', directory: '/w2', wakeByAgents: true },
  ],
};
const mateo = { kind: 'agent' as const, agentId: 'a-mateo', name: 'Mateo' };
const tomas = { kind: 'agent' as const, agentId: 'a-tomas', name: 'Tomás' };

async function setup() {
  const kv = createInMemoryAccountKv();
  await kv.transport.mutate([{ key: agentRoomKvKey('r1'), version: -1,
    value: sealAccountScopedBlobCiphertext({ kind: 'agent_room', material, payload: room, randomBytes: (n) => new Uint8Array(n) }) }]);
  return new AgentRoomStore({ transport: kv.transport, material });
}

describe('completeRoomTurn', () => {
  it('tells the user when a hand-off reaches the brake', async () => {
    const store = await setup();
    await store.appendMessage('r1', { author: { kind: 'user' }, text: '@Mateo @Tomás platiquen', mentions: ['a-mateo', 'a-tomas'] });
    for (let turn = 1; turn < AGENT_ROOM_MAX_AGENT_TURNS; turn += 1) {
      await store.appendMessage('r1', turn % 2 ? { author: tomas, text: '@Mateo', mentions: ['a-mateo'] } : { author: mateo, text: '@Tomás', mentions: ['a-tomas'] });
    }
    const lastSeq = (await store.getRoom('r1'))!.room.lastSeq;
    await store.startDelivery('r1', 'a-mateo', { localId: 'room.r1.a-mateo.n', throughSeq: lastSeq }, null);
    const push = { sendToAllDevicesAsync: vi.fn(async () => {}) };

    const outcome = await completeRoomTurn({
      store, delivery: { roomId: 'r1', agentId: 'a-mateo', localId: 'room.r1.a-mateo.n' }, author: mateo,
      reply: { finished: true, text: 'Te toca, @Tomás' }, push, pushEnabled: () => true,
    });

    expect(outcome).toBe('finished');
    expect(push.sendToAllDevicesAsync).toHaveBeenCalledTimes(1);
    expect(push.sendToAllDevicesAsync).toHaveBeenCalledWith('Room on hold', expect.stringContaining('App nueva'), { type: 'room_brake', roomId: 'r1', seq: lastSeq + 1 });
  });

  it('leaves a turn that has not finished, and pushes nothing when the user turned pushes off', async () => {
    const store = await setup();
    await store.startDelivery('r1', 'a-mateo', { localId: 'room.r1.a-mateo.n', throughSeq: 0 }, null);
    const push = { sendToAllDevicesAsync: vi.fn(async () => {}) };
    const delivery = { roomId: 'r1', agentId: 'a-mateo', localId: 'room.r1.a-mateo.n' };

    expect(await completeRoomTurn({ store, delivery, author: mateo, reply: { finished: false, text: 'a medias' }, push, pushEnabled: () => true }))
      .toBe('running');
    expect(await completeRoomTurn({ store, delivery, author: mateo, reply: { finished: true, text: '@Manny listo' }, push, pushEnabled: () => false }))
      .toBe('finished');
    expect(push.sendToAllDevicesAsync).not.toHaveBeenCalled();
  });
});

import { EventEmitter } from 'node:events';

import { afterEach, describe, expect, it, vi } from 'vitest';

import { agentRoomKvKey, sealAccountScopedBlobCiphertext, type AgentRoomV1 } from '@happier-dev/protocol';

import { createInMemoryAccountKv } from '@/api/kv/inMemoryAccountKv.testkit';

import { notifyRoomTurnReady, resetAgentRoomsForTests, startAgentRooms } from './startAgentRooms';

const machineKey = new Uint8Array(32).fill(2);
const credentials = { token: 't', encryption: { type: 'dataKey' as const, publicKey: new Uint8Array(32), machineKey } };
const material = { type: 'dataKey' as const, machineKey };
const env = { HAPPIER_AGENT_IDENTITY_JSON: JSON.stringify({ v: 1, id: 'a-mateo', name: 'Mateo', emoji: '🤖' }) };
const room: AgentRoomV1 = {
  v: 1, id: 'r1', title: 'App nueva', userName: 'Manny', lastSeq: 0, createdAt: 0, updatedAt: 0,
  members: [
    { agentId: 'a-mateo', name: 'Mateo', machineId: 'm1', directory: '/w1' },
    { agentId: 'a-tomas', name: 'Tomás', machineId: 'm2', directory: '/w2' },
  ],
};

afterEach(() => resetAgentRoomsForTests());

async function setup(readTurnReply: (sessionId: string, localId: string) => Promise<{ finished: boolean; text: string | null } | null>) {
  const kv = createInMemoryAccountKv();
  await kv.transport.mutate([{ key: agentRoomKvKey('r1'), version: -1,
    value: sealAccountScopedBlobCiphertext({ kind: 'agent_room', material, payload: room, randomBytes: (n) => new Uint8Array(n) }) }]);
  const push = { sendToAllDevicesAsync: vi.fn(async () => {}) };
  const session = Object.assign(new EventEmitter(), { sessionId: 's1' });
  const rooms = startAgentRooms(session, credentials, { transport: kv.transport, env, readTurnReply, push, pushEnabled: () => true })!;
  await rooms.store.appendMessage('r1', { author: { kind: 'user' }, text: '@Mateo ¿cómo vas?', mentions: ['a-mateo'] });
  await rooms.store.startDelivery('r1', 'a-mateo', { localId: 'room.r1.a-mateo.n1', throughSeq: 1 }, null);
  return { rooms, session, push };
}

describe('startAgentRooms', () => {
  it('posts the final text of a room turn as the agent\'s reply when the turn is ready, and moves its marker', async () => {
    const readTurnReply = vi.fn(async () => ({ finished: true, text: 'Voy bien. @Manny ¿lo subo?' }));
    const { rooms, session, push } = await setup(readTurnReply);

    session.emit('provider-input-delivered', { localId: 'room.r1.a-mateo.n1' });
    await notifyRoomTurnReady('s1');

    expect(readTurnReply).toHaveBeenCalledWith('s1', 'room.r1.a-mateo.n1');
    const [reply] = await rooms.store.readMessages('r1', { fromSeq: 2, toSeq: 2 });
    expect(reply).toMatchObject({
      text: 'Voy bien. @Manny ¿lo subo?', mentionsUser: true,
      author: { kind: 'agent', agentId: 'a-mateo', name: 'Mateo', emoji: '🤖', sessionId: 's1' },
    });
    const seat = (await rooms.store.getSeats('r1', ['a-mateo'])).get('a-mateo')!.seat;
    expect(seat).toMatchObject({ readThroughSeq: 1 });
    expect(seat.inFlight).toBeUndefined();
    expect(push.sendToAllDevicesAsync).toHaveBeenCalledWith('Mateo 🤖 mentioned you', 'App nueva: Voy bien. @Manny ¿lo subo?', { type: 'room_mention', roomId: 'r1', seq: 2 });
  });

  it('leaves turns that did not come from a room alone', async () => {
    const readTurnReply = vi.fn(async () => ({ finished: true, text: 'otra cosa' }));
    const { rooms, session } = await setup(readTurnReply);

    session.emit('provider-input-delivered', { localId: 'ui-typed-1' });
    await notifyRoomTurnReady('s1');

    expect(readTurnReply).not.toHaveBeenCalled();
    expect((await rooms.store.getRoom('r1'))!.room.lastSeq).toBe(1);
  });
});

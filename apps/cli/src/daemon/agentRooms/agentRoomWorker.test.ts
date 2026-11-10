import { describe, expect, it, vi } from 'vitest';

import { agentRoomKvKey, agentRoomMessageKvKey, sealAccountScopedBlobCiphertext, type AgentRoomV1 } from '@happier-dev/protocol';

import { createInMemoryAccountKv } from '@/api/kv/inMemoryAccountKv.testkit';
import { AgentRoomStore } from '@/session/agentRooms/agentRoomStore';

import { runAgentRoomWorker, type RoomUpdatesSocket } from './agentRoomWorker';
import type { RoomDeliveryDeps } from './reconcileRoomDeliveries';

const material = { type: 'dataKey', machineKey: new Uint8Array(32).fill(9) } as const;
const room = (id: string, machineId: string): AgentRoomV1 => ({
  v: 1, id, title: id, lastSeq: 0, createdAt: 0, updatedAt: 0,
  members: [{ agentId: 'a-mateo', name: 'Mateo', machineId, directory: '/w' }],
});

/** The relay socket boundary: the test plays the relay's connect and `kv-batch-update` events. */
function fakeSocket() {
  const handlers: { connect: Array<() => void>; update: Array<(update: unknown) => void> } = { connect: [], update: [] };
  const socket: RoomUpdatesSocket = {
    onConnect: (listener) => { handlers.connect.push(listener); },
    onUpdate: (listener) => { handlers.update.push(listener); },
    connect: vi.fn(),
    disconnect: vi.fn(),
  };
  return {
    socket,
    connect: () => handlers.connect.forEach((listener) => listener()),
    update: (keys: string[]) => handlers.update.forEach((listener) => listener({ body: { t: 'kv-batch-update', changes: keys.map((key) => ({ key, value: 'x', version: 0 })) } })),
  };
}

async function setup() {
  const kv = createInMemoryAccountKv();
  for (const [id, machineId] of [['r-here', 'm1'], ['r-away', 'm2']] as const) {
    await kv.transport.mutate([{ key: agentRoomKvKey(id), version: -1,
      value: sealAccountScopedBlobCiphertext({ kind: 'agent_room', material, payload: room(id, machineId), randomBytes: (n) => new Uint8Array(n) }) }]);
  }
  const store = new AgentRoomStore({ transport: kv.transport, material });
  const deps: RoomDeliveryDeps = {
    store,
    machineId: 'm1',
    readAgentProfile: async () => ({ v: 1, id: 'a-mateo', name: 'Mateo', providerId: 'codex', account: { label: 'x' }, updatedAt: 0 }),
    startThread: vi.fn(async () => ({ ok: true as const, sessionId: 's1' })),
    sendToThread: vi.fn(async () => ({ ok: true as const })),
    readTurnReply: async () => null,
    push: null,
    pushEnabled: () => true,
  };
  return { store, deps };
}

describe('runAgentRoomWorker', () => {
  it('delivers a room\'s new mention as soon as its write reaches the socket', async () => {
    const { store, deps } = await setup();
    const relay = fakeSocket();
    const worker = runAgentRoomWorker({ socket: relay.socket, deps });
    expect(relay.socket.connect).toHaveBeenCalled();

    await store.appendMessage('r-here', { author: { kind: 'user' }, text: '@Mateo hola', mentions: ['a-mateo'] });
    relay.update([agentRoomMessageKvKey('r-here', 1), 'task/t1']);
    await worker.settled();

    expect(deps.startThread).toHaveBeenCalledTimes(1);
    worker.stop();
    expect(relay.socket.disconnect).toHaveBeenCalled();
  });

  it('catches up on connect with the rooms this machine has a member in', async () => {
    const { store, deps } = await setup();
    await store.appendMessage('r-here', { author: { kind: 'user' }, text: '@Mateo hola', mentions: ['a-mateo'] });
    await store.appendMessage('r-away', { author: { kind: 'user' }, text: '@Mateo hola', mentions: ['a-mateo'] });
    const getRoom = vi.spyOn(store, 'getRoom');
    const relay = fakeSocket();
    const worker = runAgentRoomWorker({ socket: relay.socket, deps });

    relay.connect();
    await vi.waitFor(() => expect(deps.startThread).toHaveBeenCalledTimes(1));
    await worker.settled();
    expect(getRoom.mock.calls.map((call) => call[0])).toEqual(['r-here']);
    worker.stop();
  });
});

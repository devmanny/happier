import { describe, expect, it } from 'vitest';

import {
  agentRoomKvKey,
  agentRoomMessageKvKey,
  agentRoomSeatKvKey,
  openAccountScopedBlobCiphertext,
  parseAgentRoomMessageV1,
  sealAccountScopedBlobCiphertext,
  type AgentRoomV1,
} from '@happier-dev/protocol';

import type { AccountKvTransport } from '@/api/kv/accountKvHttpTransport';
import { createInMemoryAccountKv } from '@/api/kv/inMemoryAccountKv.testkit';

import { AgentRoomStore } from './agentRoomStore';

const material = { type: 'dataKey', machineKey: new Uint8Array(32).fill(6) } as const;
const seal = (payload: unknown) => sealAccountScopedBlobCiphertext({ kind: 'agent_room', material, payload, randomBytes: (n) => new Uint8Array(n) });
const open = (value: string) => openAccountScopedBlobCiphertext({ kind: 'agent_room', material, ciphertext: value })?.value;

const baseRoom: AgentRoomV1 = {
  v: 1, id: 'r1', title: 'App nueva', lastSeq: 0, createdAt: 0, updatedAt: 0,
  members: [{ agentId: 'a-mateo', name: 'Mateo', machineId: 'm1', directory: '/work' }],
};

async function seedRoom(kv: ReturnType<typeof createInMemoryAccountKv>, room: Record<string, unknown> = baseRoom) {
  await kv.transport.mutate([{ key: agentRoomKvKey('r1'), value: seal(room), version: -1 }]);
}

/** Lets every writer read the room before any of them writes, so their appends collide. */
function collidingWriters(transport: AccountKvTransport, writers: number): AccountKvTransport {
  let reads = 0;
  let release!: () => void;
  const allRead = new Promise<void>((resolve) => { release = resolve; });
  return {
    ...transport,
    async bulkGet(keys) {
      const rows = await transport.bulkGet(keys);
      if (keys.includes(agentRoomKvKey('r1')) && ++reads === writers) release();
      return rows;
    },
    async mutate(mutations) {
      await allRead;
      return await transport.mutate(mutations);
    },
  };
}

describe('AgentRoomStore', () => {
  it('gives two writers appending at once consecutive seqs, with no gap and no message lost', async () => {
    const kv = createInMemoryAccountKv();
    await seedRoom(kv);
    const transport = collidingWriters(kv.transport, 2);
    const manny = new AgentRoomStore({ transport, material, now: () => 10 });
    const mateo = new AgentRoomStore({ transport, material, now: () => 20 });

    const [first, second] = await Promise.all([
      manny.appendMessage('r1', { author: { kind: 'user' }, text: '@Mateo ¿cómo vamos?' }),
      mateo.appendMessage('r1', { author: { kind: 'agent', agentId: 'a-mateo', name: 'Mateo' }, text: 'Ya casi.' }),
    ]);

    expect([first!.seq, second!.seq].sort()).toEqual([1, 2]);
    expect((await manny.getRoom('r1'))!.room.lastSeq).toBe(2);
    const stored = [1, 2].map((seq) => parseAgentRoomMessageV1(open(kv.rows.get(agentRoomMessageKvKey('r1', seq))!.value!)));
    expect(stored.map((message) => message?.text).sort()).toEqual(['@Mateo ¿cómo vamos?', 'Ya casi.']);
  });

  it('keeps fields a newer build added to the room when it appends', async () => {
    const kv = createInMemoryAccountKv();
    await seedRoom(kv, { ...baseRoom, futureField: { keep: true } });
    const store = new AgentRoomStore({ transport: kv.transport, material, now: () => 5 });
    await store.appendMessage('r1', { author: { kind: 'user' }, text: 'Hola' });
    expect(open(kv.rows.get(agentRoomKvKey('r1'))!.value!)).toMatchObject({ lastSeq: 1, futureField: { keep: true } });
  });

  it('does not append to a room that does not exist', async () => {
    const kv = createInMemoryAccountKv();
    const store = new AgentRoomStore({ transport: kv.transport, material });
    expect(await store.appendMessage('r1', { author: { kind: 'user' }, text: 'Hola' })).toBeNull();
    expect(kv.rows.size).toBe(0);
  });

  it('stops instead of retrying forever when the next seq is already taken behind the room\'s back', async () => {
    const kv = createInMemoryAccountKv();
    await seedRoom(kv);
    await kv.transport.mutate([{ key: agentRoomMessageKvKey('r1', 1), value: seal({ stray: true }), version: -1 }]);
    const store = new AgentRoomStore({ transport: kv.transport, material });
    await expect(store.appendMessage('r1', { author: { kind: 'user' }, text: 'Hola' })).rejects.toThrow(/seq 1/);
  });

  it('reads a range in seq order, over as many bulk reads as it takes', async () => {
    const kv = createInMemoryAccountKv();
    await seedRoom(kv);
    const store = new AgentRoomStore({ transport: kv.transport, material });
    for (let index = 1; index <= 130; index += 1) {
      await store.appendMessage('r1', { author: { kind: 'user' }, text: `mensaje ${index}` });
    }

    const messages = await store.readMessages('r1', { fromSeq: 3, toSeq: 125 });
    expect(messages.map((message) => message.seq)).toEqual(Array.from({ length: 123 }, (_, index) => index + 3));
    expect(messages[0]!.text).toBe('mensaje 3');
  });

  it('finishes a turn in one write: the reply posted, the marker on what the turn got, the delivery cleared', async () => {
    const kv = createInMemoryAccountKv();
    await seedRoom(kv, { ...baseRoom, userName: 'Manny', members: [...baseRoom.members, { agentId: 'a-tomas', name: 'Tomás', machineId: 'm2', directory: '/w' }] });
    const store = new AgentRoomStore({ transport: kv.transport, material, now: () => 50 });
    await store.appendMessage('r1', { author: { kind: 'user' }, text: '@Mateo ¿cómo vas?', mentions: ['a-mateo'] });
    expect(await store.startDelivery('r1', 'a-mateo', { localId: 'room.r1.a-mateo.n', throughSeq: 1 }, null)).toBe(true);
    await store.appendMessage('r1', { author: { kind: 'user' }, text: 'mientras trabaja' });

    const author = { kind: 'agent' as const, agentId: 'a-mateo', name: 'Mateo', sessionId: 's1' };
    const finished = await store.finishTurn({ roomId: 'r1', agentId: 'a-mateo', localId: 'room.r1.a-mateo.n', author, text: 'Listo. @Tomás revisa; @Manny decide' });

    expect(finished).toMatchObject({ finished: true, message: { seq: 3, mentions: ['a-tomas'], mentionsUser: true, author } });
    const seat = (await store.getSeats('r1', ['a-mateo'])).get('a-mateo')!.seat;
    expect(seat.readThroughSeq).toBe(1);
    expect(seat.inFlight).toBeUndefined();
    expect((await store.getRoom('r1'))!.room.lastSeq).toBe(3);
  });

  it('finishes a delivery only once, and never one that is not in flight', async () => {
    const kv = createInMemoryAccountKv();
    await seedRoom(kv);
    const store = new AgentRoomStore({ transport: kv.transport, material });
    await store.startDelivery('r1', 'a-mateo', { localId: 'room.r1.a-mateo.n', throughSeq: 0 }, null);
    const author = { kind: 'agent' as const, agentId: 'a-mateo', name: 'Mateo' };
    const finish = (localId: string) => store.finishTurn({ roomId: 'r1', agentId: 'a-mateo', localId, author, text: 'Hecho' });

    expect(await finish('room.r1.a-mateo.other')).toEqual({ finished: false });
    expect((await finish('room.r1.a-mateo.n')).finished).toBe(true);
    expect(await finish('room.r1.a-mateo.n')).toEqual({ finished: false });
    expect((await store.getRoom('r1'))!.room.lastSeq).toBe(1);
  });

  it('lets only one of two concurrent deliveries claim a member', async () => {
    const kv = createInMemoryAccountKv();
    await seedRoom(kv);
    const store = new AgentRoomStore({ transport: kv.transport, material });
    const claims = await Promise.all([
      store.startDelivery('r1', 'a-mateo', { localId: 'room.r1.a-mateo.a', throughSeq: 0 }, null),
      store.startDelivery('r1', 'a-mateo', { localId: 'room.r1.a-mateo.b', throughSeq: 0 }, null),
    ]);
    expect(claims.sort()).toEqual([false, true]);
    expect(kv.rows.has(agentRoomSeatKvKey('r1', 'a-mateo'))).toBe(true);
  });
});

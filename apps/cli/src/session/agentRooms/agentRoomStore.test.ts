import { describe, expect, it } from 'vitest';

import {
  agentRoomKvKey,
  agentRoomMessageKvKey,
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
});

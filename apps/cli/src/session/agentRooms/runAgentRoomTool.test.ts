import { describe, expect, it } from 'vitest';

import { agentRoomKvKey, sealAccountScopedBlobCiphertext, type AgentRoomV1 } from '@happier-dev/protocol';

import { createInMemoryAccountKv } from '@/api/kv/inMemoryAccountKv.testkit';

import { AgentRoomStore } from './agentRoomStore';
import { runAgentRoomTool } from './runAgentRoomTool';

const material = { type: 'dataKey', machineKey: new Uint8Array(32).fill(7) } as const;
const room: AgentRoomV1 = {
  v: 1, id: 'r1', title: 'App nueva', lastSeq: 0, createdAt: 0, updatedAt: 0,
  members: [
    { agentId: 'a-mateo', name: 'Mateo', emoji: '🤖', machineId: 'm1', directory: '/work/app-movil' },
    { agentId: 'a-tomas', name: 'Tomás', machineId: 'm2', directory: '/work/app-escritorio' },
  ],
};
const mateo = { agent: { id: 'a-mateo', name: 'Mateo', emoji: '🤖' }, sessionId: 's1' };

async function setup(messages: number) {
  const kv = createInMemoryAccountKv();
  await kv.transport.mutate([{ key: agentRoomKvKey('r1'), version: -1,
    value: sealAccountScopedBlobCiphertext({ kind: 'agent_room', material, payload: room, randomBytes: (n) => new Uint8Array(n) }) }]);
  const store = new AgentRoomStore({ transport: kv.transport, material, now: () => Date.parse('2026-11-10T12:00:00Z') });
  for (let index = 1; index <= messages; index += 1) {
    await store.appendMessage('r1', index % 2
      ? { author: { kind: 'user' }, text: `pregunta ${index}` }
      : { author: { kind: 'agent', agentId: 'a-tomas', name: 'Tomás' }, text: `respuesta ${index}` });
  }
  return { store };
}

describe('runAgentRoomTool (sala_leer)', () => {
  it('reads the room\'s latest messages with who said each one, oldest first', async () => {
    const { store } = await setup(3);
    const result = await runAgentRoomTool({ store, caller: mateo, operation: 'read', input: { roomId: 'r1' } });
    expect(result).toEqual({
      ok: true, roomId: 'r1', title: 'App nueva', lastSeq: 3, fromSeq: 1, toSeq: 3,
      members: [{ agentId: 'a-mateo', name: 'Mateo' }, { agentId: 'a-tomas', name: 'Tomás' }],
      messages: [
        { seq: 1, at: '2026-11-10T12:00:00.000Z', from: 'user', text: 'pregunta 1' },
        { seq: 2, at: '2026-11-10T12:00:00.000Z', from: 'Tomás', text: 'respuesta 2' },
        { seq: 3, at: '2026-11-10T12:00:00.000Z', from: 'user', text: 'pregunta 3' },
      ],
    });
  });

  it('reads an older range the agent asks for', async () => {
    const { store } = await setup(6);
    const result = await runAgentRoomTool({ store, caller: mateo, operation: 'read', input: { roomId: 'r1', fromSeq: 2, toSeq: 3 } }) as any;
    expect(result.messages.map((message: { seq: number }) => message.seq)).toEqual([2, 3]);
    expect(result).toMatchObject({ fromSeq: 2, toSeq: 3, lastSeq: 6, earlier: { toSeq: 1 } });
  });

  it('returns one bulk read of the newest messages in the range and says where the earlier ones end', async () => {
    const { store } = await setup(130);
    const result = await runAgentRoomTool({ store, caller: mateo, operation: 'read', input: { roomId: 'r1' } }) as any;
    expect(result.messages).toHaveLength(100);
    expect(result).toMatchObject({ fromSeq: 31, toSeq: 130, earlier: { toSeq: 30 } });
  });

  it('only lets the room\'s members read it', async () => {
    const { store } = await setup(1);
    const leo = { agent: { id: 'a-leo', name: 'Leo' }, sessionId: 's9' };
    expect(await runAgentRoomTool({ store, caller: leo, operation: 'read', input: { roomId: 'r1' } }))
      .toEqual({ ok: false, error: 'You are not a member of room r1.' });
    expect(await runAgentRoomTool({ store, caller: { agent: null, sessionId: 's9' }, operation: 'read', input: { roomId: 'r1' } }))
      .toEqual({ ok: false, error: 'You are not a member of room r1.' });
    expect(await runAgentRoomTool({ store, caller: mateo, operation: 'read', input: { roomId: 'r404' } }))
      .toEqual({ ok: false, error: 'room r404 not found' });
    expect(await runAgentRoomTool({ store, caller: mateo, operation: 'read', input: {} }))
      .toEqual({ ok: false, error: 'roomId is required' });
  });
});

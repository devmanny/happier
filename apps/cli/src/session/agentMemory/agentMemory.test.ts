import { describe, expect, it } from 'vitest';

import { openAccountScopedBlobCiphertext, sealAccountScopedBlobCiphertext } from '@happier-dev/protocol';

import { createInMemoryAccountKv } from '@/api/kv/inMemoryAccountKv.testkit';

import { AgentMemory } from './agentMemory';

const material = { type: 'dataKey', machineKey: new Uint8Array(32).fill(6) } as const;

function setup(sessionId = 's-self') {
  const kv = createInMemoryAccountKv();
  const clock = { now: Date.UTC(2026, 10, 7, 9, 0) };
  let ids = 0;
  const memory = new AgentMemory({
    agentId: 'a-julian',
    sessionId,
    transport: kv.transport,
    material,
    now: () => clock.now,
    newId: () => `id-${++ids}`,
    today: () => '2026-11-07',
    describeSelf: () => ({ title: 'Agentes etapa 2', directory: '~/Projects/Happier', host: 'Mac mini' }),
  });
  const read = (key: string) => {
    const value = kv.rows.get(key)?.value;
    return value ? openAccountScopedBlobCiphertext({ kind: 'agent_memory', material, ciphertext: value })?.value : null;
  };
  const put = (key: string, payload: unknown) => {
    kv.rows.set(key, {
      value: sealAccountScopedBlobCiphertext({ kind: 'agent_memory', material, payload, randomBytes: (n) => new Uint8Array(n) }),
      version: (kv.rows.get(key)?.version ?? -1) + 1,
    });
  };
  return { kv, clock, memory, read, put };
}

describe('AgentMemory', () => {
  it('keeps this thread\'s now: the title when a turn starts, then what the agent says', async () => {
    const { memory, read, clock } = setup();
    await memory.touchNow();
    expect(read('agent/a-julian/now/s-self')).toMatchObject({ text: 'Agentes etapa 2', directory: '~/Projects/Happier' });

    await memory.setNow('Escribiendo pruebas de memoria');
    clock.now += 60_000;
    await memory.touchNow();
    expect(read('agent/a-julian/now/s-self')).toMatchObject({ text: 'Escribiendo pruebas de memoria', updatedAt: clock.now });
  });

  it('appends journal entries under their own keys, so threads never overwrite each other', async () => {
    const { memory, read } = setup();
    await memory.appendJournal('Decidí usar UserPromptSubmit');
    await memory.appendJournal('Subí el build');
    expect(read('agent/a-julian/journal/2026-11-07/id-1')).toMatchObject({ text: 'Decidí usar UserPromptSubmit', sessionId: 's-self' });
    expect(read('agent/a-julian/journal/2026-11-07/id-2')).toMatchObject({ text: 'Subí el build' });
  });

  it('creates and edits notes, retrying when another thread changed the note first', async () => {
    const { memory, read, put } = setup();
    const created = await memory.writeNote({ title: 'Manny', markdown: 'Prefiere respuestas cortas.' });
    expect(created.id).toBe('id-1');
    put('agent/a-julian/note/id-1', { v: 1, id: 'id-1', title: 'Manny', markdown: 'Cambiado por otro hilo', updatedAt: 1 });
    await memory.writeNote({ noteId: 'id-1', title: 'Manny', markdown: 'Prefiere respuestas cortas. Ver [[Happier]].' });
    expect(read('agent/a-julian/note/id-1')).toMatchObject({ markdown: 'Prefiere respuestas cortas. Ver [[Happier]].' });
  });

  it('summarizes the agent\'s other threads for the start of a turn, and nothing when it is alone', async () => {
    const { memory, put, clock } = setup();
    expect(await memory.turnContextBlock()).toBeNull();
    put('agent/a-julian/now/s-other', { v: 1, sessionId: 's-other', text: 'Revisando TestFlight', updatedAt: clock.now - 5 * 60_000 });
    put('agent/a-tomas/now/s-tomas', { v: 1, sessionId: 's-tomas', text: 'Otro agente', updatedAt: clock.now });
    memory.invalidateTurnContext();
    const block = await memory.turnContextBlock();
    expect(block).toContain('s-other: Revisando TestFlight (5 min ago)');
    expect(block).not.toContain('Otro agente');
  });

  it('searches its own memory after decrypting it', async () => {
    const { memory } = setup();
    await memory.appendJournal('Subí el build 202611070147 a TestFlight');
    await memory.writeNote({ title: 'Happier', markdown: 'Fork nativo de Apple' });
    const hits = await memory.search('testflight');
    expect(hits.items.map((hit) => hit.kind)).toEqual(['journal']);
    expect((await memory.read({ kind: 'notes' })).items.map((record) => record.kind)).toEqual(['note']);
  });
});

import { describe, expect, it, vi } from 'vitest';

import { createInMemoryAccountKv } from '@/api/kv/inMemoryAccountKv.testkit';

import { AgentMemory } from './agentMemory';
import { runAgentMemoryTool } from './runAgentMemoryTool';

const material = { type: 'dataKey', machineKey: new Uint8Array(32).fill(2) } as const;

function memoryFor(sessionId: string, kv = createInMemoryAccountKv()) {
  return {
    kv,
    memory: new AgentMemory({
      agentId: 'a1', sessionId, transport: kv.transport, material,
      today: () => '2026-11-07', describeSelf: () => ({ title: `Hilo ${sessionId}` }),
    }),
  };
}

describe('runAgentMemoryTool', () => {
  it('writes the journal and notes, and reads them back', async () => {
    const { memory } = memoryFor('s1');
    expect(await runAgentMemoryTool({ memory, operation: 'write', input: { kind: 'journal', text: 'Subí el build' } }))
      .toMatchObject({ ok: true });
    const note = await runAgentMemoryTool({ memory, operation: 'write', input: { kind: 'note', title: 'Manny', markdown: 'Ver [[Happier]]' } });
    expect(note).toMatchObject({ ok: true, noteId: expect.any(String) });
    const journal = await runAgentMemoryTool({ memory, operation: 'read', input: { kind: 'journal' } }) as any;
    expect(journal.records.map((r: any) => r.text)).toEqual(['Subí el build']);
    const found = await runAgentMemoryTool({ memory, operation: 'search', input: { query: 'happier' } }) as any;
    expect(found.records.map((r: any) => r.title)).toEqual(['Manny']);
  });

  it('explains what is missing instead of writing an empty record', async () => {
    const { memory } = memoryFor('s1');
    expect(await runAgentMemoryTool({ memory, operation: 'write', input: { kind: 'journal' } }))
      .toMatchObject({ ok: false, error: expect.stringContaining('text') });
    expect(await runAgentMemoryTool({ memory, operation: 'write', input: { kind: 'note', markdown: 'x' } }))
      .toMatchObject({ ok: false, error: expect.stringContaining('title') });
  });

  it('lists its other threads and reads one of them, but not a session of another agent', async () => {
    const kv = createInMemoryAccountKv();
    const { memory: other } = memoryFor('s-other', kv);
    await other.setNow('Revisando TestFlight');
    const { memory } = memoryFor('s1', kv);
    await memory.setNow('Etapa 2');
    const readThreadMessages = vi.fn(async () => [{ role: 'agent', text: 'Build subido', createdAt: 1 }]);

    const list = await runAgentMemoryTool({ memory, operation: 'threads', input: {}, readThreadMessages }) as any;
    expect(list.threads.map((t: any) => [t.sessionId, t.isThisThread]).sort()).toEqual([['s-other', false], ['s1', true]]);

    const read = await runAgentMemoryTool({ memory, operation: 'threads', input: { threadSessionId: 's-other' }, readThreadMessages }) as any;
    expect(read).toMatchObject({ ok: true, messages: [{ text: 'Build subido' }] });
    expect(readThreadMessages).toHaveBeenCalledWith('s-other', 10);

    expect(await runAgentMemoryTool({ memory, operation: 'threads', input: { threadSessionId: 's-stranger' }, readThreadMessages }))
      .toMatchObject({ ok: false });
  });
});

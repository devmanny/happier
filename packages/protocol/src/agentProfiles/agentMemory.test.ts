import { describe, expect, it } from 'vitest';

import {
  agentJournalKvKey,
  agentNoteKvKey,
  agentNowKvKey,
  buildOtherThreadsSummary,
  extractNoteLinks,
  parseAgentMemoryKvKey,
  searchAgentMemory,
  type AgentMemoryRecord,
} from './agentMemory.js';
import { openAccountScopedBlobCiphertext, sealAccountScopedBlobCiphertext } from '../crypto/accountScopedCipher.js';

const material = { type: 'dataKey', machineKey: new Uint8Array(32).fill(3) } as const;

describe('agent memory keys', () => {
  it('keeps keys opaque and parses them back', () => {
    expect(agentNowKvKey('a1', 's1')).toBe('agent/a1/now/s1');
    expect(agentJournalKvKey('a1', '2026-11-07', 'e1')).toBe('agent/a1/journal/2026-11-07/e1');
    expect(agentNoteKvKey('a1', 'n1')).toBe('agent/a1/note/n1');
    expect(parseAgentMemoryKvKey('agent/a1/journal/2026-11-07/e1')).toEqual({ agentId: 'a1', kind: 'journal', day: '2026-11-07', id: 'e1' });
    expect(parseAgentMemoryKvKey('agent/a1/now/s1')).toEqual({ agentId: 'a1', kind: 'now', id: 's1' });
    expect(parseAgentMemoryKvKey('agent/a1/note/n1')).toEqual({ agentId: 'a1', kind: 'note', id: 'n1' });
    expect(parseAgentMemoryKvKey('agent/a1/profile')).toBeNull();
  });

  it('seals memory under its own kind', () => {
    const ciphertext = sealAccountScopedBlobCiphertext({ kind: 'agent_memory', material, payload: { text: 'x' }, randomBytes: (n) => new Uint8Array(n) });
    expect(openAccountScopedBlobCiphertext({ kind: 'agent_memory', material, ciphertext })?.value).toEqual({ text: 'x' });
    expect(openAccountScopedBlobCiphertext({ kind: 'agent_profile', material, ciphertext })).toBeNull();
  });
});

describe('other threads summary', () => {
  it('lists the agent\'s other threads, newest first, with how long ago', () => {
    const now = 10 * 60_000;
    const summary = buildOtherThreadsSummary({
      selfSessionId: 's-self',
      now,
      nows: [
        { v: 1, sessionId: 's-self', text: 'this one', updatedAt: now },
        { v: 1, sessionId: 's-old', text: 'Login app móvil', title: 'Login', directory: '~/Projects/app', host: 'Mac mini', updatedAt: now - 8 * 60_000 },
        { v: 1, sessionId: 's-new', text: 'Revisando TestFlight', updatedAt: now - 30_000 },
      ],
    });
    expect(summary.split('\n')).toEqual([
      '- s-new: Revisando TestFlight (less than a minute ago)',
      '- s-old: Login app móvil — Login · Mac mini ~/Projects/app (8 min ago)',
    ]);
    expect(buildOtherThreadsSummary({ selfSessionId: 's', now, nows: [] })).toBe('');
  });
});

describe('memory search', () => {
  const records: AgentMemoryRecord[] = [
    { kind: 'note', key: 'agent/a/note/n1', value: { v: 1, id: 'n1', title: 'Manny', markdown: 'Prefiere respuestas cortas. Ver [[Happier]].', updatedAt: 1 } },
    { kind: 'journal', key: 'agent/a/journal/2026-11-07/e1', value: { v: 1, id: 'e1', sessionId: 's1', text: 'Subí el build 202611070147 a TestFlight', at: 2 } },
    { kind: 'now', key: 'agent/a/now/s1', value: { v: 1, sessionId: 's1', text: 'Etapa 2: memoria', updatedAt: 3 } },
  ];

  it('matches every term, ignoring case and accents', () => {
    expect(searchAgentMemory(records, 'testflight build').map((hit) => hit.key)).toEqual(['agent/a/journal/2026-11-07/e1']);
    expect(searchAgentMemory(records, 'MANNY cortas').map((hit) => hit.key)).toEqual(['agent/a/note/n1']);
    expect(searchAgentMemory(records, 'subi').map((hit) => hit.key)).toEqual(['agent/a/journal/2026-11-07/e1']);
    expect(searchAgentMemory(records, 'nada parecido')).toEqual([]);
  });

  it('finds [[links]] in notes', () => {
    expect(extractNoteLinks('Ver [[Happier]] y [[Tareas|las tareas]].')).toEqual(['Happier', 'Tareas']);
  });
});

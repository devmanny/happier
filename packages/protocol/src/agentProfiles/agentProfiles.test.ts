import { describe, expect, it } from 'vitest';

import {
  openAccountScopedBlobCiphertext,
  sealAccountScopedBlobCiphertext,
} from '../crypto/accountScopedCipher.js';
import {
  agentProfileKvKey,
  buildAgentIdentityPromptTextV1,
  parseAgentIdentityV1,
} from './agentIdentity.js';
import {
  AGENT_PRESENCE_STALE_AFTER_MS,
  agentPresenceKvKey,
  describePresenceConflict,
  findPresenceConflicts,
  parseAgentPresenceV1,
  type AgentPresenceV1,
} from './agentPresence.js';

const material = { type: 'dataKey', machineKey: new Uint8Array(32).fill(7) } as const;

function presence(overrides: Partial<AgentPresenceV1> = {}): AgentPresenceV1 {
  return {
    v: 1,
    sessionId: 'other',
    agent: { id: 'a-mateo', name: 'Mateo', emoji: '🤖' },
    providerId: 'codex',
    machineId: 'm1',
    host: 'Mac mini',
    directory: '/repo',
    task: 'Login app móvil',
    files: [{ path: '/repo/apps/apple/Composer.swift', since: 1_000 }],
    resources: [{ name: 'build-ios', since: 2_000 }],
    updatedAt: 10_000,
    ...overrides,
  };
}

describe('agent identity', () => {
  it('accepts a named agent and rejects a blank name', () => {
    expect(parseAgentIdentityV1({ v: 1, id: 'a1', name: ' Julián ', emoji: '🤖', description: 'Arquitecto' }))
      .toEqual({ v: 1, id: 'a1', name: 'Julián', emoji: '🤖', description: 'Arquitecto' });
    expect(parseAgentIdentityV1({ v: 1, id: 'a1', name: '   ' })).toBeNull();
    expect(parseAgentIdentityV1('{"v":1,"id":"a1","name":"Tomás"}')).toEqual({ v: 1, id: 'a1', name: 'Tomás' });
    expect(parseAgentIdentityV1('not json')).toBeNull();
  });

  it('tells the model who it is and carries the description verbatim', () => {
    const text = buildAgentIdentityPromptTextV1({ v: 1, id: 'a1', name: 'Julián', emoji: '🤖', description: 'Firma como Julián 🤖.' });
    expect(text).toContain('Julián');
    expect(text).toContain('Firma como Julián 🤖.');
    // One agent across threads: the memory rules travel with the identity.
    for (const tool of ['memoria_anotar', 'ahora_actualizar', 'memoria_buscar', 'mis_hilos']) expect(text).toContain(tool);
  });

  it('keeps titles out of the clear-text key', () => {
    expect(agentProfileKvKey('0f1e')).toBe('agent/0f1e/profile');
    expect(agentPresenceKvKey('cmv1')).toBe('presence/cmv1');
  });

  it('seals profiles and presence under their own kinds', () => {
    const ciphertext = sealAccountScopedBlobCiphertext({ kind: 'agent_profile', material, payload: { name: 'Mateo' }, randomBytes: (n) => new Uint8Array(n).fill(1) });
    expect(openAccountScopedBlobCiphertext({ kind: 'agent_profile', material, ciphertext })?.value).toEqual({ name: 'Mateo' });
    expect(openAccountScopedBlobCiphertext({ kind: 'agent_presence', material, ciphertext })).toBeNull();
  });
});

describe('presence conflicts', () => {
  const now = 10_000 + 30_000;

  it('warns about a file another live thread is editing', () => {
    const conflicts = findPresenceConflicts({
      selfSessionId: 'me',
      records: [presence()],
      now,
      filePath: '/repo/apps/apple/Composer.swift',
    });
    expect(conflicts).toHaveLength(1);
    const text = describePresenceConflict(conflicts[0]!, now);
    expect(text).toContain('Mateo');
    expect(text).toContain('Login app móvil');
    expect(text).toContain('Composer.swift');
  });

  it('warns about a shared resource in use', () => {
    const conflicts = findPresenceConflicts({ selfSessionId: 'me', records: [presence()], now, resource: 'build-ios' });
    expect(conflicts.map((c) => c.kind)).toEqual(['resource']);
  });

  it('ignores its own thread, other files and threads that stopped signalling', () => {
    expect(findPresenceConflicts({ selfSessionId: 'other', records: [presence()], now, filePath: '/repo/apps/apple/Composer.swift' })).toEqual([]);
    expect(findPresenceConflicts({ selfSessionId: 'me', records: [presence()], now, filePath: '/repo/README.md' })).toEqual([]);
    expect(findPresenceConflicts({
      selfSessionId: 'me',
      records: [presence()],
      now: 10_000 + AGENT_PRESENCE_STALE_AFTER_MS + 1,
      filePath: '/repo/apps/apple/Composer.swift',
    })).toEqual([]);
  });

  it('parses only well-formed presence records', () => {
    expect(parseAgentPresenceV1(presence())).toEqual(presence());
    expect(parseAgentPresenceV1({ v: 1, sessionId: 'x' })).toBeNull();
  });
});

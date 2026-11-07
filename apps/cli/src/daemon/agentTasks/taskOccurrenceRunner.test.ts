import { describe, expect, it } from 'vitest';

import { sealAccountScopedBlobCiphertext } from '@happier-dev/protocol';

import { createInMemoryAccountKv } from '@/api/kv/inMemoryAccountKv.testkit';

import { readAgentProfileFromKv, readLiveThreadIds } from './taskOccurrenceRunner';

const material = { type: 'dataKey', machineKey: new Uint8Array(32).fill(5) } as const;
const seal = (kind: 'agent_profile' | 'agent_presence', payload: unknown) =>
  sealAccountScopedBlobCiphertext({ kind, material, payload, randomBytes: (n) => new Uint8Array(n) });
const profile = (name: string) => ({ v: 1, id: 'a1', name, providerId: 'codex', account: { label: 'ChatGPT' }, updatedAt: 1 });

describe('task occurrence runner reads', () => {
  it('reads the agent profile from its own prefix, falling back to where older builds kept it', async () => {
    const kv = createInMemoryAccountKv();
    kv.rows.set('agent/a1/profile', { value: seal('agent_profile', profile('Viejo')), version: 0 });
    expect((await readAgentProfileFromKv(kv.transport, material, 'a1'))?.name).toBe('Viejo');
    kv.rows.set('agentprofile/a1', { value: seal('agent_profile', profile('Nuevo')), version: 0 });
    expect((await readAgentProfileFromKv(kv.transport, material, 'a1'))?.name).toBe('Nuevo');
    expect(await readAgentProfileFromKv(kv.transport, material, 'missing')).toBeNull();
  });

  it('counts a thread as working only while its presence record is live', async () => {
    const kv = createInMemoryAccountKv();
    const now = 10 * 60_000;
    const record = (sessionId: string, updatedAt: number) => ({
      v: 1, sessionId, agent: null, providerId: 'codex', machineId: null, host: null, directory: null, task: null,
      files: [], resources: [], updatedAt,
    });
    kv.rows.set('presence/s-live', { value: seal('agent_presence', record('s-live', now - 30_000)), version: 0 });
    kv.rows.set('presence/s-stale', { value: seal('agent_presence', record('s-stale', now - 9 * 60_000)), version: 0 });
    expect([...await readLiveThreadIds(kv.transport, material, now)]).toEqual(['s-live']);
  });
});

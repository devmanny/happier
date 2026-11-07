import { describe, expect, it, vi } from 'vitest';

import { sealAccountScopedBlobCiphertext } from '@happier-dev/protocol';

import { createInMemoryAccountKv } from '@/api/kv/inMemoryAccountKv.testkit';

import { readAgentProfileFromKv, readLiveThreadIds, startOccurrenceThread } from './taskOccurrenceRunner';

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

describe('startOccurrenceThread', () => {
  const spawn = {
    directory: '/repo', backendTarget: { kind: 'builtInAgent' as const, agentId: 'claude' },
    agentIdentity: { v: 1 as const, id: 'a1', name: 'Mateo' }, modelId: 'claude-haiku-5-5', effort: 'low', permissionMode: 'yolo',
  };

  it('waits for the session id when the daemon accepted the spawn before knowing it', async () => {
    const spawnSession = vi.fn(async () => ({ type: 'success' as const, sessionIdStatus: 'pending' as const, spawnNonce: 'automation:run1' }));
    const resolveSpawnSessionByNonce = vi.fn(async () => ({ status: 'success' as const, sessionId: 's-new' }));
    const started = await startOccurrenceThread({ spawnSession, resolveSpawnSessionByNonce }, spawn, 'Do it', 'run1');
    expect(started).toEqual({ ok: true, sessionId: 's-new' });
    expect(spawnSession).toHaveBeenCalledWith(expect.objectContaining({
      directory: '/repo', agentIdentity: spawn.agentIdentity, modelId: 'claude-haiku-5-5', permissionMode: 'yolo', spawnNonce: 'automation:run1',
      pendingFirstInput: expect.objectContaining({ text: 'Do it' }),
    }));
  });

  it('reports the daemon\'s error', async () => {
    const spawnSession = vi.fn(async () => ({ type: 'error' as const, errorCode: 'SPAWN_FAILED' as const, errorMessage: 'boom' }));
    expect(await startOccurrenceThread({ spawnSession, resolveSpawnSessionByNonce: vi.fn() }, spawn, 'x', 'run2'))
      .toEqual({ ok: false, code: 'SPAWN_FAILED', message: 'boom' });
  });
});

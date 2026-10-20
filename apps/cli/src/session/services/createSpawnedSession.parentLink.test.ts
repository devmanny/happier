import { beforeEach, describe, expect, it, vi } from 'vitest';

import type { Credentials } from '@/persistence';

const spawnDaemonSession = vi.hoisted(() => vi.fn());
const fetchSessionById = vi.hoisted(() => vi.fn());
const updateSessionMetadataWithRetry = vi.hoisted(() => vi.fn(async () => {}));

vi.mock('@/daemon/controlClient', async (importOriginal) => ({
  ...await importOriginal<typeof import('@/daemon/controlClient')>(),
  spawnDaemonSession,
}));

vi.mock('@/session/transport/http/sessionsHttp', async (importOriginal) => ({
  ...await importOriginal<typeof import('@/session/transport/http/sessionsHttp')>(),
  fetchSessionById,
}));

vi.mock('@/session/metadata/updateSessionMetadataWithRetry', () => ({
  updateSessionMetadataWithRetry,
}));

import { createSpawnedSession } from './createSpawnedSession';

type MetadataUpdater = (metadata: Record<string, unknown>) => Record<string, unknown>;

describe('createSpawnedSession parent link', () => {
  const credentials: Credentials = {
    token: 'token',
    encryption: { type: 'legacy', secret: new Uint8Array([1, 2, 3, 4]) },
  };

  beforeEach(() => {
    spawnDaemonSession.mockReset();
    fetchSessionById.mockReset();
    updateSessionMetadataWithRetry.mockClear();
    spawnDaemonSession.mockResolvedValue({ success: true, sessionId: 'child-1' });
    fetchSessionById.mockResolvedValue({
      id: 'child-1',
      createdAt: 1,
      updatedAt: 1,
      active: true,
      activeAt: 1,
      pendingCount: 0,
      metadataVersion: 1,
      metadata: { path: '/repo', host: 'host' },
    });
  });

  it('records the session that spawned the child in its metadata', async () => {
    await createSpawnedSession({
      credentials,
      directory: '/repo',
      backendTarget: { kind: 'builtInAgent', agentId: 'claude' },
      parentSessionId: 'parent-1',
    });

    expect(updateSessionMetadataWithRetry).toHaveBeenCalledOnce();
    const [{ sessionId, updater }] = updateSessionMetadataWithRetry.mock.calls[0] as unknown as [
      { sessionId: string; updater: MetadataUpdater },
    ];
    expect(sessionId).toBe('child-1');
    const updated = updater({ path: '/repo' });
    expect(updated.path).toBe('/repo');
    expect(updated.spawnedBySessionV1).toEqual({ v: 1, parentSessionId: 'parent-1', createdAtMs: expect.any(Number) });
  });

  it('writes nothing extra for a session started outside another session', async () => {
    await createSpawnedSession({
      credentials,
      directory: '/repo',
      backendTarget: { kind: 'builtInAgent', agentId: 'claude' },
    });

    expect(updateSessionMetadataWithRetry).not.toHaveBeenCalled();
  });
});

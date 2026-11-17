import { describe, expect, it, vi } from 'vitest';

import type { Credentials } from '@/persistence';
import type { SpawnSessionOptions } from '@/rpc/handlers/registerSessionHandlers';

import { resolveRespawnSessionRuntimeSnapshot } from './resolveRespawnSessionRuntimeSnapshot';

const persistedConnectedServices = {
  v: 1,
  bindingsByServiceId: {
    'openai-codex': {
      source: 'connected',
      selection: 'profile',
      profileId: 'persisted-codex-profile',
    },
  },
} as const;

const persistedMaterializationIdentity = {
  v: 1,
  id: 'csm_respawn_snapshot_1',
  createdAtMs: 123,
} as const;

function defaultRespawnOptions(overrides: Partial<SpawnSessionOptions> = {}): SpawnSessionOptions {
  return {
    directory: '/tmp/repo',
    existingSessionId: 'session-1',
    backendTarget: { kind: 'builtInAgent', agentId: 'codex' },
    approvedNewDirectoryCreation: true,
    ...overrides,
  };
}

function credentials(token: string): Credentials {
  return {
    token,
    encryption: { type: 'legacy', secret: new Uint8Array(32) },
  };
}

describe('resolveRespawnSessionRuntimeSnapshot', () => {
  it('applies the persisted runtime snapshot before respawning a tracked session', async () => {
    const readCredentials = vi.fn(async () => credentials('fresh-token'));
    const resolveAttachContext = vi.fn(async () => ({
      ok: true as const,
      attachPayload: { v: 2 as const, encryptionMode: 'plain' as const },
      vendorResumeId: 'persisted-vendor-resume',
      sessionPath: '/tmp/repo',
      deliveredUserMessageSeq: null,
      metadata: {
        connectedServices: persistedConnectedServices,
        connectedServiceMaterializationIdentityV1: persistedMaterializationIdentity,
        connectedServicesUpdatedAt: 700,
        permissionMode: 'yolo',
        permissionModeUpdatedAt: 710,
        sessionModeOverrideV1: { v: 1, modeId: 'build', updatedAt: 720 },
        modelOverrideV1: { v: 1, modelId: 'gpt-5.3-codex', updatedAt: 730 },
      },
    }));

    const trackedSpawnOptions = defaultRespawnOptions({
      permissionMode: 'default',
      permissionModeUpdatedAt: 100,
      connectedServices: { v: 1, bindingsByServiceId: {} },
      connectedServicesUpdatedAt: 100,
      resume: 'stale-vendor-resume',
    });

    const result = await resolveRespawnSessionRuntimeSnapshot({
      sessionId: 'session-1',
      spawnOptions: trackedSpawnOptions,
      vendorResumeId: 'tracked-vendor-resume',
      defaultOptions: defaultRespawnOptions({
        permissionMode: 'default',
        permissionModeUpdatedAt: 100,
        connectedServices: { v: 1, bindingsByServiceId: {} },
        connectedServicesUpdatedAt: 100,
        resume: 'stale-vendor-resume',
      }),
      credentials: credentials('stale-token'),
      readCredentials,
      resolveAttachContext,
    });

    expect(readCredentials).toHaveBeenCalledTimes(1);
    expect(resolveAttachContext).toHaveBeenCalledWith(expect.objectContaining({
      token: 'fresh-token',
      sessionId: 'session-1',
      backendTarget: { kind: 'builtInAgent', agentId: 'codex' },
    }));
    expect(result).toMatchObject({
      connectedServices: persistedConnectedServices,
      connectedServiceMaterializationIdentityV1: persistedMaterializationIdentity,
      connectedServicesUpdatedAt: 700,
      permissionMode: 'yolo',
      permissionModeUpdatedAt: 710,
      agentModeId: 'build',
      agentModeUpdatedAt: 720,
      modelId: 'gpt-5.3-codex',
      modelUpdatedAt: 730,
      resume: 'stale-vendor-resume',
    });
  });

  it('falls back to default respawn options when persisted metadata cannot be loaded', async () => {
    const defaultOptions = defaultRespawnOptions({ resume: 'vendor-resume' });
    const result = await resolveRespawnSessionRuntimeSnapshot({
      sessionId: 'session-1',
      spawnOptions: defaultOptions,
      vendorResumeId: 'vendor-resume',
      defaultOptions,
      credentials: credentials('token'),
      readCredentials: async () => null,
      resolveAttachContext: async () => ({ ok: false as const, reason: 'missingToken' }),
    });

    expect(result).toBe(defaultOptions);
  });

  it('uses the canonical default backend target when legacy respawn options omit it', async () => {
    const resolveAttachContext = vi.fn(async () => ({
      ok: true as const,
      attachPayload: { v: 2 as const, encryptionMode: 'plain' as const },
      vendorResumeId: 'claude-session-1',
      sessionPath: '/tmp/repo',
      deliveredUserMessageSeq: null,
      metadata: {
        permissionMode: 'yolo',
        permissionModeUpdatedAt: 710,
      },
    }));
    const legacyOptions = defaultRespawnOptions({ backendTarget: undefined });

    const result = await resolveRespawnSessionRuntimeSnapshot({
      sessionId: 'session-1',
      spawnOptions: legacyOptions,
      vendorResumeId: 'claude-session-1',
      defaultOptions: legacyOptions,
      credentials: credentials('token'),
      readCredentials: async () => null,
      resolveAttachContext,
    });

    expect(resolveAttachContext).toHaveBeenCalledWith(expect.objectContaining({
      backendTarget: { kind: 'builtInAgent', agentId: 'claude' },
    }));
    expect(result).toMatchObject({
      permissionMode: 'yolo',
      permissionModeUpdatedAt: 710,
    });
  });
  it("respawns the Agent the Session names, not the Agent of the exited runner", async () => {
    // Incident 2026-11-17: after a Claude -> Codex switch a stale Claude runner kept the Session;
    // its connected-service restart relaunched `happier claude` from the tracked options.
    const resolveAttachContext = vi.fn(async (input: { backendTarget: { kind: string; agentId?: string } }) => ({
      ok: true as const,
      attachPayload: { v: 2 as const, encryptionMode: 'plain' as const },
      vendorResumeId: input.backendTarget.agentId === 'claude' ? 'claude-session-1' : null,
      sessionPath: '/tmp/repo',
      deliveredUserMessageSeq: null,
      metadata: {
        path: '/tmp/repo',
        machineId: 'machine-1',
        flavor: 'codex',
        permissionMode: 'yolo',
        permissionModeUpdatedAt: 710,
        modelOverrideV1: { v: 1, modelId: 'gpt-6.1-sol', updatedAt: 730 },
      },
    }));
    const trackedClaudeOptions = defaultRespawnOptions({
      machineId: 'machine-1',
      backendTarget: { kind: 'builtInAgent', agentId: 'claude' },
      modelId: 'claude-opus-5-5',
      modelUpdatedAt: 100,
      resume: 'claude-session-1',
      environmentVariables: { HAPPIER_CLAUDE_ENDPOINT_STATE: 'x' },
    });

    const result = await resolveRespawnSessionRuntimeSnapshot({
      sessionId: 'session-1',
      spawnOptions: trackedClaudeOptions,
      vendorResumeId: 'claude-session-1',
      defaultOptions: trackedClaudeOptions,
      credentials: credentials('token'),
      readCredentials: async () => null,
      resolveAttachContext,
    });

    expect(result.backendTarget).toEqual({ kind: 'builtInAgent', agentId: 'codex' });
    expect(result).toMatchObject({
      existingSessionId: 'session-1',
      directory: '/tmp/repo',
      permissionMode: 'yolo',
      modelId: 'gpt-6.1-sol',
    });
    expect(result.resume).toBeUndefined();
    expect(result.environmentVariables?.HAPPIER_CLAUDE_ENDPOINT_STATE).toBeUndefined();
  });
});

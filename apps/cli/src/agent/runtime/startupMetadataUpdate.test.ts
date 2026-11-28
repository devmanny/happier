import { describe, expect, it, vi } from 'vitest';

import type { Metadata } from '@/api/types';

import { SessionAttachRuntimeIdentityConflictError } from './mergeSessionMetadataForStartup';
import {
  applyStartupMetadataUpdateToSession,
  buildAcpSessionModeOverride,
  buildModelOverride,
  buildPermissionModeOverride,
} from './startupMetadataUpdate';

describe('startupMetadataUpdate', () => {
  it('returns null when no explicit permissionMode is provided', () => {
    expect(buildPermissionModeOverride({})).toBeNull();
  });

  it('builds a permissionMode override when permissionMode is provided', () => {
    expect(buildPermissionModeOverride({ permissionMode: 'yolo', permissionModeUpdatedAt: 123 })).toEqual({
      mode: 'yolo',
      updatedAt: 123,
    });
  });

  it('returns null when no explicit agent mode is provided', () => {
    expect(buildAcpSessionModeOverride({})).toBeNull();
  });

  it('builds an ACP session mode override when agentModeId is provided', () => {
    expect(buildAcpSessionModeOverride({ agentModeId: 'plan', agentModeUpdatedAt: 123 })).toEqual({
      modeId: 'plan',
      updatedAt: 123,
    });
  });

  it('returns null when no explicit model is provided', () => {
    expect(buildModelOverride({})).toBeNull();
  });

  it('builds a model override when modelId is provided', () => {
    expect(buildModelOverride({ modelId: 'gpt-5-codex-high', modelUpdatedAt: 123 })).toEqual({
      modelId: 'gpt-5-codex-high',
      updatedAt: 123,
    });
  });

  it('preserves exact nonblank opaque model identifiers', () => {
    expect(buildModelOverride({ modelId: ' model-a ', modelUpdatedAt: 123 })).toEqual({
      modelId: ' model-a ',
      updatedAt: 123,
    });
  });

  it('applies mergeSessionMetadataForStartup via session.updateMetadata', () => {
    const updates: Metadata[] = [];
    const fakeSession = {
      updateMetadata: (updater: (current: Metadata) => Metadata) => {
        const current = {
          lifecycleState: 'archived',
          codexSessionId: 'codex-1',
        } as any as Metadata;
        updates.push(updater(current));
      },
    };

    applyStartupMetadataUpdateToSession({
      session: fakeSession,
      next: { hostPid: 42 } as any,
      nowMs: 999,
      permissionModeOverride: null,
    });

    expect(updates).toHaveLength(1);
    expect(updates[0].lifecycleState).toBe('running');
    expect((updates[0] as any).hostPid).toBe(42);
    expect((updates[0] as any).codexSessionId).toBe('codex-1');
  });

  it('fails the attach when the Session it re-reads names another Agent, and keeps other write failures non-fatal', async () => {
    const attachTo = (updateMetadata: (updater: (current: Metadata) => Metadata) => Promise<void>) =>
      applyStartupMetadataUpdateToSession({
        session: { updateMetadata },
        next: { flavor: 'claude', hostPid: 42 } as any,
        nowMs: 999,
        permissionModeOverride: null,
        mode: 'attach',
      });

    // The server's current view (a switch committed after the runner's snapshot) names Codex.
    await expect(attachTo(async (updater) => {
      updater({ flavor: 'codex' } as any as Metadata);
    })).rejects.toBeInstanceOf(SessionAttachRuntimeIdentityConflictError);
    await expect(attachTo(async () => {
      throw new Error('socket offline');
    })).resolves.toBeUndefined();
  });

  it('binds the runtime to its own Agent whatever its startup write did, and not when the attach is refused', async () => {
    // The runtime's Agent is a fact of its process: a runner whose write failed still serves the
    // Session and must still stop once the Session names another Agent.
    const attachWith = async (updateMetadata: (updater: (current: Metadata) => Metadata) => Promise<void>) => {
      const bindRuntimeBackendTarget = vi.fn();
      await applyStartupMetadataUpdateToSession({
        session: { updateMetadata, bindRuntimeBackendTarget },
        next: { flavor: 'codex', hostPid: 42 } as any,
        nowMs: 999,
        permissionModeOverride: null,
        mode: 'attach',
      }).catch(() => undefined);
      return bindRuntimeBackendTarget;
    };

    const admitted = await attachWith(async (updater) => {
      updater({ flavor: 'codex' } as any as Metadata);
    });
    expect(admitted).toHaveBeenCalledWith({ kind: 'builtInAgent', agentId: 'codex' });
    const failed = await attachWith(async () => {
      throw new Error('socket offline');
    });
    expect(failed).toHaveBeenCalledWith({ kind: 'builtInAgent', agentId: 'codex' });
    const refused = await attachWith(async (updater) => {
      updater({ flavor: 'claude' } as any as Metadata);
    });
    expect(refused).not.toHaveBeenCalled();
  });

  it('passes an explicit ACP session mode override through to startup metadata merge', () => {
    const updates: Metadata[] = [];
    const fakeSession = {
      updateMetadata: (updater: (current: Metadata) => Metadata) => {
        const current = {
          lifecycleState: 'archived',
        } as any as Metadata;
        updates.push(updater(current));
      },
    };

    applyStartupMetadataUpdateToSession({
      session: fakeSession,
      next: { hostPid: 42 } as any,
      nowMs: 999,
      permissionModeOverride: null,
      acpSessionModeOverride: { modeId: 'plan', updatedAt: 123 } as any,
    } as any);

    expect((updates[0] as any).acpSessionModeOverrideV1).toEqual({ v: 1, updatedAt: 123, modeId: 'plan' });
  });

  it('passes an explicit model override through to startup metadata merge', () => {
    const updates: Metadata[] = [];
    const fakeSession = {
      updateMetadata: (updater: (current: Metadata) => Metadata) => {
        const current = {
          lifecycleState: 'archived',
        } as any as Metadata;
        updates.push(updater(current));
      },
    };

    applyStartupMetadataUpdateToSession({
      session: fakeSession,
      next: { hostPid: 42 } as any,
      nowMs: 999,
      permissionModeOverride: null,
      modelOverride: { modelId: 'gpt-5-codex-high', updatedAt: 123 } as any,
    } as any);

    expect((updates[0] as any).modelOverrideV1).toEqual({ v: 1, updatedAt: 123, modelId: 'gpt-5-codex-high' });
  });

  it('can remove specific metadata keys during attach startup updates', () => {
    const updates: Metadata[] = [];
    const fakeSession = {
      updateMetadata: (updater: (current: Metadata) => Metadata) => {
        const current = {
          lifecycleState: 'archived',
          acpSessionModesV1: { v: 1, provider: 'codex' },
          acpSessionModelsV1: { v: 1, provider: 'codex' },
          acpConfigOptionsV1: { v: 1, provider: 'codex' },
        } as any as Metadata;
        updates.push(updater(current));
      },
    };

    applyStartupMetadataUpdateToSession({
      session: fakeSession,
      next: { hostPid: 42 } as any,
      nowMs: 999,
      permissionModeOverride: null,
      mode: 'attach',
      metadataKeysToUnsetOnAttach: ['acpSessionModesV1', 'acpSessionModelsV1', 'acpConfigOptionsV1'],
    } as any);

    expect((updates[0] as any).acpSessionModesV1).toBeUndefined();
    expect((updates[0] as any).acpSessionModelsV1).toBeUndefined();
    expect((updates[0] as any).acpConfigOptionsV1).toBeUndefined();
    expect((updates[0] as any).hostPid).toBe(42);
  });
});

import type { Metadata, PermissionMode } from '@/api/types';
import { logger } from '@/ui/logger';
import type { SessionAttachMetadataIdentityPolicy } from '@happier-dev/protocol';
import { readNonBlankSessionControlIdentifier } from '@/agent/runtime/sessionControlIdentifiers';
import {
  bindSessionClientToRuntimeAgent,
  type RuntimeAgentBindableSession,
} from '@/agent/runtime/sessionRuntimeAgentBinding';

import {
  mergeSessionMetadataForStartup,
  SessionAttachRuntimeIdentityConflictError,
  type AcpSessionModeOverride as MergeAcpSessionModeOverride,
  type ModelOverride as MergeModelOverride,
  type PermissionModeOverride as MergePermissionModeOverride,
} from './mergeSessionMetadataForStartup';

export type PermissionModeOverride = MergePermissionModeOverride | null;

export type AcpSessionModeOverride = MergeAcpSessionModeOverride | null;

export type ModelOverride = MergeModelOverride | null;

export function buildAcpSessionModeOverride(opts: {
  agentModeId?: string;
  agentModeUpdatedAt?: number;
}): AcpSessionModeOverride {
  const normalized = readNonBlankSessionControlIdentifier(opts.agentModeId) ?? '';
  if (!normalized) return null;
  return { modeId: normalized, updatedAt: opts.agentModeUpdatedAt };
}

export function buildPermissionModeOverride(opts: {
  permissionMode?: PermissionMode;
  permissionModeUpdatedAt?: number;
}): PermissionModeOverride {
  if (typeof opts.permissionMode !== 'string') {
    return null;
  }
  return { mode: opts.permissionMode, updatedAt: opts.permissionModeUpdatedAt };
}

export function buildModelOverride(opts: {
  modelId?: string;
  modelUpdatedAt?: number;
}): ModelOverride {
  const normalized = readNonBlankSessionControlIdentifier(opts.modelId) ?? '';
  if (!normalized) return null;
  return { modelId: normalized, updatedAt: opts.modelUpdatedAt };
}

export function applyStartupMetadataUpdateToSession(opts: {
  session: RuntimeAgentBindableSession & {
    updateMetadata: (updater: (current: Metadata) => Metadata) => Promise<void> | void;
  };
  next: Metadata;
  nowMs?: number;
  permissionModeOverride: PermissionModeOverride;
  acpSessionModeOverride?: AcpSessionModeOverride;
  modelOverride?: ModelOverride;
  metadataKeysToUnsetOnAttach?: readonly string[] | null;
  attachMetadataIdentityPolicy?: SessionAttachMetadataIdentityPolicy | null;
  mode?: 'start' | 'attach';
}): Promise<void> {
  const nowMs = typeof opts.nowMs === 'number' ? opts.nowMs : Date.now();

  try {
    const result = opts.session.updateMetadata((currentMetadata) =>
      mergeSessionMetadataForStartup({
        current: currentMetadata,
        next: opts.next,
        nowMs,
        permissionModeOverride: opts.permissionModeOverride ?? null,
        acpSessionModeOverride: opts.acpSessionModeOverride ?? null,
        modelOverride: opts.modelOverride ?? null,
        metadataKeysToUnsetOnAttach: opts.metadataKeysToUnsetOnAttach ?? null,
        attachMetadataIdentityPolicy: opts.attachMetadataIdentityPolicy ?? null,
        mode: opts.mode ?? 'start',
      }),
    );
    // Bound once the write settles (never before, so an identity-replacing attach's own write lands
    // first), whatever its outcome: a runtime whose write failed still serves the Session. A refused
    // attach is not bound; its runner exits.
    return Promise.resolve(result).then(() => {
      bindSessionClientToRuntimeAgent(opts.session, opts.next);
    }, (error) => {
      if (error instanceof SessionAttachRuntimeIdentityConflictError) throw error;
      logger.debug('[startupMetadata] Failed to update session metadata (apply_startup_metadata_update) (non-fatal)', error);
      bindSessionClientToRuntimeAgent(opts.session, opts.next);
    });
  } catch (error) {
    if (error instanceof SessionAttachRuntimeIdentityConflictError) return Promise.reject(error);
    logger.debug('[startupMetadata] Failed to update session metadata (apply_startup_metadata_update) (non-fatal)', error);
    bindSessionClientToRuntimeAgent(opts.session, opts.next);
    return Promise.resolve();
  }
}

import { buildBackendTargetKey, SPAWN_SESSION_ERROR_CODES, type BackendTargetRefV1 } from '@happier-dev/protocol';

import {
  buildInactiveSessionResumeSpawnOptions,
  resolveSessionPersistedRuntimeIdentity,
} from '@/daemon/sessions/runtimeSnapshot/buildInactiveSessionResumeSpawnOptions';
import type { SpawnSessionOptions, SpawnSessionResult } from '@/rpc/handlers/registerSessionHandlers';

export function describeBackendTarget(target: BackendTargetRefV1): string {
  return target.kind === 'builtInAgent' ? target.agentId : `ACP backend ${target.backendId}`;
}

/**
 * The one rule for which runtime may serve an existing Session: the Agent its persisted current
 * view names (`resolveSessionPersistedRuntimeIdentity`). Every runtime decision about an existing
 * Session — a launch, rejoining a pending launch, adopting a live runner, and the runner's own
 * attach — compares its Agent with that identity, never with the (possibly stale) request that
 * asked for it.
 *
 * Returns the Session's Agent when `backendTarget` contradicts it, else `null`. Unknown on either
 * side is not proof of a different Agent.
 */
export function resolveSessionRuntimeBackendConflict(input: Readonly<{
  sessionMetadata: Record<string, unknown> | null | undefined;
  backendTarget: BackendTargetRefV1 | null | undefined;
}>): BackendTargetRefV1 | null {
  if (!input.backendTarget || !input.sessionMetadata) return null;
  const sessionBackendTarget = resolveSessionPersistedRuntimeIdentity(input.sessionMetadata)?.backendTarget;
  if (!sessionBackendTarget) return null;
  return buildBackendTargetKey(sessionBackendTarget) === buildBackendTargetKey(input.backendTarget)
    ? null
    : sessionBackendTarget;
}

export type ExistingSessionLaunchResolution =
  | Readonly<{
      type: 'launch';
      options: SpawnSessionOptions;
      /** The Agent a stale request named, when the launch was retargeted away from it. */
      retargetedFrom: BackendTargetRefV1 | null;
    }>
  /** The request runs on another machine than the Session's, or the Session has no persisted placement. */
  | Readonly<{ type: 'placement_mismatch'; sessionBackendTarget: BackendTargetRefV1; backendTarget: BackendTargetRefV1 }>;

/**
 * The options a launch (or respawn) for an existing Session runs with: always the Agent the
 * Session's persisted current view names.
 *
 * - A request that names no Agent runs the Session's Agent with the rest of the request.
 * - A request that names another Agent is a stale view (an automation's stored target, a client
 *   view or tracked runner from before an Agent switch). It is retargeted: rebuilt from the
 *   persisted Session exactly as a cold resume would be (`buildInactiveSessionResumeSpawnOptions`),
 *   so the old Agent's resume id, model, mode and provider environment never carry over, and at
 *   the Session's persisted placement (a cold resume's canonical directory), however the request
 *   spelled its directory. Only the request's own authority, idempotency nonce and prompt carriers
 *   survive. A request for another machine than the Session's, or a Session without a persisted
 *   placement, is a `placement_mismatch`.
 * - An explicit `replace_with_runtime_identity` attach (handoff) and a Session whose Agent is
 *   unknown keep the request.
 */
export function resolveExistingSessionLaunchOptions(input: Readonly<{
  sessionId: string;
  options: SpawnSessionOptions;
  sessionMetadata: Record<string, unknown> | null | undefined;
}>): ExistingSessionLaunchResolution {
  const { options, sessionMetadata } = input;
  const unchanged = { type: 'launch', options, retargetedFrom: null } as const;
  if (options.attachMetadataIdentityPolicy === 'replace_with_runtime_identity' || !sessionMetadata) return unchanged;
  const sessionBackendTarget = resolveSessionPersistedRuntimeIdentity(sessionMetadata)?.backendTarget;
  if (!sessionBackendTarget) return unchanged;
  if (!options.backendTarget) {
    return { type: 'launch', options: { ...options, backendTarget: sessionBackendTarget }, retargetedFrom: null };
  }
  if (!resolveSessionRuntimeBackendConflict({ sessionMetadata, backendTarget: options.backendTarget })) return unchanged;

  const rebuilt = buildInactiveSessionResumeSpawnOptions({
    sessionId: input.sessionId,
    rawSession: { machineId: options.machineId ?? null },
    metadata: sessionMetadata,
    fallbackMachineId: options.machineId ?? null,
    ...(typeof options.initialTranscriptAfterSeq === 'number'
      ? { initialTranscriptAfterSeq: options.initialTranscriptAfterSeq }
      : {}),
    ...(options.executionAuthorization ? { executionAuthorization: options.executionAuthorization } : {}),
  });
  if (!rebuilt) return { type: 'placement_mismatch', sessionBackendTarget, backendTarget: options.backendTarget };
  return {
    type: 'launch',
    options: {
      ...rebuilt,
      ...(options.spawnNonce ? { spawnNonce: options.spawnNonce } : {}),
      ...(typeof options.accountSettingsVersionHint === 'number'
        ? { accountSettingsVersionHint: options.accountSettingsVersionHint }
        : {}),
      ...(options.pendingFirstInput ? { pendingFirstInput: options.pendingFirstInput } : {}),
      ...(options.initialGoal ? { initialGoal: options.initialGoal } : {}),
    },
    retargetedFrom: options.backendTarget,
  };
}

/**
 * The spawn owner's typed refusal for a conflict found by `resolveSessionRuntimeBackendConflict`:
 * a tracked (pending or live) runner is another Agent than the Session names. Its own error code
 * lets a caller tell it from a runtime that could not be checked.
 */
export function buildSessionRuntimeBackendConflictSpawnError(input: Readonly<{
  sessionBackendTarget: BackendTargetRefV1;
  backendTarget: BackendTargetRefV1;
}>): Extract<SpawnSessionResult, { type: 'error' }> {
  return {
    type: 'error',
    errorCode: SPAWN_SESSION_ERROR_CODES.SESSION_RUNTIME_AGENT_CONFLICT,
    errorMessage: `This session's runtime is ${describeBackendTarget(input.backendTarget)}, but the session now runs ${describeBackendTarget(input.sessionBackendTarget)}. Stop the session, then resume it.`,
  };
}

/**
 * The refusal for a stale request that cannot be retargeted because it runs where the Session does
 * not live (`placement_mismatch`). A placement problem, never an Agent conflict.
 */
export function buildExistingSessionPlacementSpawnError(input: Readonly<{
  sessionBackendTarget: BackendTargetRefV1;
}>): Extract<SpawnSessionResult, { type: 'error' }> {
  return {
    type: 'error',
    errorCode: SPAWN_SESSION_ERROR_CODES.INVALID_REQUEST,
    errorMessage: `This session now runs ${describeBackendTarget(input.sessionBackendTarget)} on another machine (or has no persisted workspace), so it cannot be resumed here. Refresh it and resume again.`,
  };
}

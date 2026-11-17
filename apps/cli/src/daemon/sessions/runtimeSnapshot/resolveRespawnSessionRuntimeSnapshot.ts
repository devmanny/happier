import type { Credentials } from '@/persistence';
import type { SpawnSessionOptions } from '@/rpc/handlers/registerSessionHandlers';
import { DEFAULT_CATALOG_AGENT_ID } from '@/backends/types';

import { resolveExistingSessionAttachContext } from '@/daemon/sessionEncryption/resolveExistingSessionAttachContext';

import { resolveExistingSessionLaunchOptions } from '@/daemon/spawn/existingSessionBackendTargetAdmission';
import { resolveSessionRuntimeSnapshot } from './resolveSessionRuntimeSnapshot';

type ResolveExistingSessionAttachContext = typeof resolveExistingSessionAttachContext;

export type ResolveRespawnSessionRuntimeSnapshotParams = Readonly<{
  sessionId: string;
  spawnOptions: SpawnSessionOptions;
  vendorResumeId: string;
  defaultOptions: SpawnSessionOptions;
  credentials: Credentials | null;
  readCredentials: () => Promise<Credentials | null>;
  resolveAttachContext?: ResolveExistingSessionAttachContext;
}>;

export async function resolveRespawnSessionRuntimeSnapshot(
  params: ResolveRespawnSessionRuntimeSnapshotParams,
): Promise<SpawnSessionOptions> {
  const resolver = params.resolveAttachContext ?? resolveExistingSessionAttachContext;
  const storedCredentials = await params.readCredentials().catch(() => null);
  const effectiveCredentials = storedCredentials ?? params.credentials;
  const token = typeof effectiveCredentials?.token === 'string' ? effectiveCredentials.token.trim() : '';
  if (!token) return params.defaultOptions;
  const backendTarget = params.defaultOptions.backendTarget
    ?? params.spawnOptions.backendTarget
    ?? { kind: 'builtInAgent' as const, agentId: DEFAULT_CATALOG_AGENT_ID };

  const attachContext = await resolver({
    token,
    sessionId: params.sessionId,
    backendTarget,
    credentials: effectiveCredentials,
  }).catch(() => null);
  if (!attachContext?.ok) return params.defaultOptions;

  // A respawn relaunches the Session, so it runs the Agent the Session's current view names.
  // When that differs from the exited runner's (an Agent switch committed after it launched),
  // the exited runner's options are a stale request: they are retargeted like any other, so the
  // old Agent's model, vendor resume id and provider environment never reach the relaunch.
  const launch = resolveExistingSessionLaunchOptions({
    sessionId: params.sessionId,
    options: { ...params.defaultOptions, backendTarget },
    sessionMetadata: attachContext.metadata,
  });
  if (launch.type === 'launch' && launch.retargetedFrom) return launch.options;

  return resolveSessionRuntimeSnapshot({
    incomingOptions: params.defaultOptions,
    persistedMetadata: attachContext.metadata,
    trackedSpawnOptions: params.spawnOptions,
    persistedVendorResumeId: attachContext.vendorResumeId,
    trackedVendorResumeId: params.vendorResumeId,
  }).spawnOptions;
}

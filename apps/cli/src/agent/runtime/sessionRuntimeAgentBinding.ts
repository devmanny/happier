import type { BackendTargetRefV1 } from '@happier-dev/protocol';

import type { Metadata } from '@/api/types';
import { resolveSessionPersistedRuntimeIdentity } from '@/daemon/sessions/runtimeSnapshot/buildInactiveSessionResumeSpawnOptions';

export type RuntimeAgentBindableSession = Readonly<{
  /** See `ApiSessionClient.bindRuntimeBackendTarget`. */
  bindRuntimeBackendTarget?: (backendTarget: BackendTargetRefV1) => void;
}>;

/**
 * Binds a runner's session client to the Agent the runner runs, read from the runner's own startup
 * metadata. That Agent is a fact of the process, so every client a runner serves its Session
 * through is bound — whatever its startup metadata write did (failed, or skipped because the
 * Session's snapshot was unreadable), and including clients an offline reconnection swaps in —
 * and the client's Agent lifetime guard is never off. A Session that names the same Agent, or none,
 * leaves a bound client untouched.
 */
export function bindSessionClientToRuntimeAgent(
  session: RuntimeAgentBindableSession,
  runtimeMetadata: Metadata,
): void {
  const runtimeBackendTarget = resolveSessionPersistedRuntimeIdentity(runtimeMetadata)?.backendTarget;
  if (runtimeBackendTarget) session.bindRuntimeBackendTarget?.(runtimeBackendTarget);
}

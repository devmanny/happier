import {
  AGENT_PRESENCE_KV_PREFIX,
  agentProfileKvKey,
  isAgentPresenceLive,
  legacyAgentProfileKvKey,
  openAccountScopedBlobCiphertext,
  parseAgentPresenceV1,
  parseAgentProfileV1,
  type AccountScopedCryptoMaterial,
  type AccountSettings,
  type AgentProfileV1,
} from '@happier-dev/protocol';

import { createAccountKvHttpTransport, type AccountKvTransport } from '@/api/kv/accountKvHttpTransport';
import { runAutomationAsNewSession } from '@/daemon/automation/automationRunNewSession';
import { awaitSpawnedSessionId, type SpawnSessionNonceResolver } from '@/session/services/awaitSpawnedSessionId';
import { resolveAccountScopedCryptoMaterial, type Credentials } from '@/persistence';
import type { SpawnSessionOptions, SpawnSessionResult } from '@/rpc/handlers/registerSessionHandlers';
import { AgentTaskStore } from '@/session/agentTasks/agentTaskStore';
import { sendSessionMessage } from '@/session/services/sendSessionMessage';

import { runTaskOccurrence, type TaskOccurrenceResult, type TaskOccurrenceSpawn } from './runTaskOccurrence';

async function readExact(transport: AccountKvTransport, key: string): Promise<string | null> {
  return (await transport.list(key)).find((row) => row.key === key)?.value ?? null;
}

/** The agent's profile: its own prefix first, then where builds before the move kept it. */
export async function readAgentProfileFromKv(
  transport: AccountKvTransport,
  material: AccountScopedCryptoMaterial,
  agentId: string,
): Promise<AgentProfileV1 | null> {
  for (const key of [agentProfileKvKey(agentId), legacyAgentProfileKvKey(agentId)]) {
    const value = await readExact(transport, key);
    const opened = value ? openAccountScopedBlobCiphertext({ kind: 'agent_profile', material, ciphertext: value }) : null;
    const profile = opened ? parseAgentProfileV1(opened.value) : null;
    if (profile) return profile;
  }
  return null;
}

/** Sessions whose presence record is live: a turn is running there. */
export async function readLiveThreadIds(
  transport: AccountKvTransport,
  material: AccountScopedCryptoMaterial,
  now: number,
): Promise<Set<string>> {
  const live = new Set<string>();
  for (const row of await transport.list(AGENT_PRESENCE_KV_PREFIX)) {
    const opened = openAccountScopedBlobCiphertext({ kind: 'agent_presence', material, ciphertext: row.value });
    const record = opened ? parseAgentPresenceV1(opened.value) : null;
    if (record && isAgentPresenceLive(record, now)) live.add(record.sessionId);
  }
  return live;
}

/**
 * Opens the occurrence's thread as the agent. The daemon may accept the spawn before the session id
 * exists (`sessionIdStatus: 'pending'`); the id is then settled by the spawn nonce, as other spawn
 * callers do.
 */
export async function startOccurrenceThread(
  deps: Readonly<{
    spawnSession: (options: SpawnSessionOptions) => Promise<SpawnSessionResult>;
    resolveSpawnSessionByNonce: SpawnSessionNonceResolver;
  }>,
  spawn: TaskOccurrenceSpawn,
  firstMessage: string,
  occurrenceId: string,
): Promise<Readonly<{ ok: true; sessionId: string }> | Readonly<{ ok: false; code: string; message: string }>> {
  const now = Date.now();
  const result = await runAutomationAsNewSession({
    spawnSession: deps.spawnSession,
    runId: occurrenceId,
    firstInputText: firstMessage,
    template: {
      directory: spawn.directory,
      backendTarget: spawn.backendTarget,
      agentIdentity: spawn.agentIdentity,
      ...(spawn.environmentVariables ? { environmentVariables: spawn.environmentVariables } : {}),
      ...(spawn.modelId ? { modelId: spawn.modelId, modelUpdatedAt: now } : {}),
      ...(spawn.effort
        ? { sessionConfigOptionOverrides: { v: 1, updatedAt: now, overrides: { reasoning_effort: { updatedAt: now, value: spawn.effort } } } }
        : {}),
      ...(spawn.permissionMode
        ? { permissionMode: spawn.permissionMode as SpawnSessionOptions['permissionMode'], permissionModeUpdatedAt: now }
        : {}),
    } as SpawnSessionOptions,
  });
  const settled = await awaitSpawnedSessionId({ result, resolveSpawnSessionByNonce: deps.resolveSpawnSessionByNonce });
  return settled.type === 'success'
    ? { ok: true, sessionId: settled.sessionId }
    : { ok: false, code: settled.errorCode, message: settled.errorMessage };
}

/** What the daemon's automation worker calls for a recurring task's run. */
export function createTaskOccurrenceRunner(params: Readonly<{
  credentials: Credentials;
  spawnSession: (options: SpawnSessionOptions) => Promise<SpawnSessionResult>;
  /** Settles a spawn the daemon accepted before it knew the session id (`daemon.spawnSession.resolve`). */
  resolveSpawnSessionByNonce: SpawnSessionNonceResolver;
  getAccountSettings: () => AccountSettings | null | undefined;
}>): ((run: Readonly<{ runId: string; dueAt?: number; taskId: string; ruleId: string }>) => Promise<TaskOccurrenceResult>) | null {
  const credentials = params.credentials;
  if (!credentials.encryption) return null;
  const transport = createAccountKvHttpTransport({ token: credentials.token });
  const material = resolveAccountScopedCryptoMaterial(credentials);
  const store = new AgentTaskStore({ transport, material });

  return async (run) => await runTaskOccurrence(run, {
    store,
    readAgentProfile: (agentId) => readAgentProfileFromKv(transport, material, agentId),
    liveThreadIds: () => readLiveThreadIds(transport, material, Date.now()),
    defaultPermissionMode: (providerId) => {
      const modes = (params.getAccountSettings() as Record<string, unknown> | null | undefined)?.sessionDefaultPermissionModeByTargetKey;
      const mode = modes && typeof modes === 'object' ? (modes as Record<string, unknown>)[`agent:${providerId}`] : undefined;
      return typeof mode === 'string' ? mode : undefined;
    },
    startNewThread: (spawn, firstMessage, occurrenceId) =>
      startOccurrenceThread({ spawnSession: params.spawnSession, resolveSpawnSessionByNonce: params.resolveSpawnSessionByNonce }, spawn, firstMessage, occurrenceId),
    continueThread: async (sessionId, message, occurrenceId) => {
      const result = await sendSessionMessage({
        credentials,
        idOrPrefix: sessionId,
        message,
        wait: false,
        timeoutMs: 60_000,
        localId: `task-occurrence:${occurrenceId}`,
        resumeInactiveSession: true,
      });
      return result.ok ? { ok: true } : { ok: false, code: result.code };
    },
  });
}

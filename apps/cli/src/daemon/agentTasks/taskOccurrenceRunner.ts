import {
  AGENT_PRESENCE_KV_PREFIX,
  agentProfileKvKey,
  isAgentPresenceLive,
  legacyAgentProfileKvKey,
  openAccountScopedBlobCiphertext,
  parseAgentPresenceV1,
  parseAgentProfileV1,
  type AccountScopedCryptoMaterial,
  type AgentProfileV1,
} from '@happier-dev/protocol';

import axios from 'axios';

import { createAccountKvHttpTransport, type AccountKvTransport } from '@/api/kv/accountKvHttpTransport';
import { resolveServerHttpBaseUrl } from '@/api/client/serverHttpBaseUrl';
import { logger } from '@/ui/logger';
import { runAutomationAsNewSession } from '@/daemon/automation/automationRunNewSession';
import { awaitSpawnedSessionId, type SpawnSessionNonceResolver } from '@/session/services/awaitSpawnedSessionId';
import { resolveAccountScopedCryptoMaterial, type Credentials } from '@/persistence';
import type { SpawnSessionOptions, SpawnSessionResult } from '@/rpc/handlers/registerSessionHandlers';
import { AgentTaskStore } from '@/session/agentTasks/agentTaskStore';
import { sendSessionMessage } from '@/session/services/sendSessionMessage';

import { runScheduledTaskStart } from './runScheduledTaskStart';
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
}>): ((run: Readonly<{ runId: string; automationId: string; dueAt?: number; taskId: string; ruleId?: string; kind: 'recurrence' | 'scheduled_start' }>) => Promise<TaskOccurrenceResult>) | null {
  const credentials = params.credentials;
  if (!credentials.encryption) return null;
  const transport = createAccountKvHttpTransport({ token: credentials.token });
  const material = resolveAccountScopedCryptoMaterial(credentials);
  const store = new AgentTaskStore({ transport, material });

  const deleteAutomation = async (automationId: string) => {
    const response = await axios.delete(`${resolveServerHttpBaseUrl()}/v2/automations/${encodeURIComponent(automationId)}`, {
      headers: { Authorization: `Bearer ${credentials.token}` },
      timeout: 15_000,
      validateStatus: () => true,
    });
    if (response.status !== 200 && response.status !== 404) {
      logger.warn('[DAEMON AUTOMATION] Could not remove a fired one-time task start (it will not run again)', { automationId, status: response.status });
    }
  };

  return async (run) => {
    const common = {
      store,
      readAgentProfile: (agentId: string) => readAgentProfileFromKv(transport, material, agentId),
      startNewThread: (spawn: TaskOccurrenceSpawn, firstMessage: string, occurrenceId: string) =>
        startOccurrenceThread({ spawnSession: params.spawnSession, resolveSpawnSessionByNonce: params.resolveSpawnSessionByNonce }, spawn, firstMessage, occurrenceId),
      continueThread: (sessionId: string, message: string, occurrenceId: string, permissionMode: string) =>
        continueThread(credentials, sessionId, message, occurrenceId, permissionMode),
    };
    if (run.kind === 'scheduled_start') {
      return await runScheduledTaskStart({ runId: run.runId, automationId: run.automationId, taskId: run.taskId }, { ...common, deleteAutomation });
    }
    if (!run.ruleId) return { type: 'failed', errorCode: 'invalid_template', errorMessage: 'a recurring task run needs its rule' };
    return await runTaskOccurrence({ runId: run.runId, ...(run.dueAt !== undefined ? { dueAt: run.dueAt } : {}), taskId: run.taskId, ruleId: run.ruleId }, {
      ...common,
      liveThreadIds: () => readLiveThreadIds(transport, material, Date.now()),
    });
  };
}

/** Sends the session a message (resuming it if inactive), through the canonical send path. */
async function continueThread(credentials: Credentials, sessionId: string, message: string, occurrenceId: string, permissionMode: string) {
  const result = await sendSessionMessage({
    credentials,
    idOrPrefix: sessionId,
    message,
    wait: false,
    timeoutMs: 60_000,
    localId: `task-occurrence:${occurrenceId}`,
    resumeInactiveSession: true,
    permissionModeOverride: permissionMode,
  });
  return result.ok ? { ok: true as const } : { ok: false as const, code: result.code };
}

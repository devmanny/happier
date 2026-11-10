import {
  agentIdentityFromProfile,
  agentProfileKvKey,
  legacyAgentProfileKvKey,
  openAccountScopedBlobCiphertext,
  parseAgentProfileV1,
  type AccountScopedCryptoMaterial,
  type AgentIdentityV1,
  type AgentProfileV1,
} from '@happier-dev/protocol';

import type { AccountKvTransport } from '@/api/kv/accountKvHttpTransport';
import type { Credentials } from '@/persistence';
import type { SpawnSessionOptions } from '@/rpc/handlers/registerSessionHandlers';
import { sendSessionMessage } from '@/session/services/sendSessionMessage';

/** What a new thread of an agent is spawned with: the agent's identity, account and engine, in a folder. */
export type AgentThreadSpawn = Readonly<{
  directory: string;
  backendTarget: Readonly<{ kind: 'builtInAgent'; agentId: string }>;
  agentIdentity: AgentIdentityV1;
  environmentVariables?: Record<string, string>;
  modelId?: string;
  effort?: string;
  permissionMode?: string;
}>;

/** A new thread of the agent of `profile` in `directory` (a task's, or its seat in a room). */
export function spawnAsAgent(profile: AgentProfileV1, directory: string, permissionMode: string): AgentThreadSpawn {
  const configDir = profile.account.configDir?.trim();
  return {
    directory,
    backendTarget: { kind: 'builtInAgent', agentId: profile.providerId },
    agentIdentity: agentIdentityFromProfile(profile),
    ...(profile.providerId === 'claude' && configDir ? { environmentVariables: { CLAUDE_CONFIG_DIR: configDir } } : {}),
    ...(profile.modelId && profile.modelId !== 'default' ? { modelId: profile.modelId } : {}),
    ...(profile.effort ? { effort: profile.effort } : {}),
    permissionMode,
  };
}

/** The daemon spawn options for an agent thread (model, effort and permission mode stamped `now`). */
export function agentThreadSpawnOptions(spawn: AgentThreadSpawn, now: number): SpawnSessionOptions {
  return {
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
  } as SpawnSessionOptions;
}

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

/**
 * Sends an agent's existing thread a message (resuming it if inactive) through the canonical send
 * path, without waiting for its turn. `permissionMode` is the message's permission intent; the
 * session's own mode is not changed. A retry with the same `localId` lands once.
 */
export async function sendToAgentThread(params: Readonly<{
  credentials: Credentials;
  sessionId: string;
  message: string;
  localId: string;
  permissionMode: string;
}>): Promise<Readonly<{ ok: true }> | Readonly<{ ok: false; code: string }>> {
  const result = await sendSessionMessage({
    credentials: params.credentials,
    idOrPrefix: params.sessionId,
    message: params.message,
    wait: false,
    timeoutMs: 60_000,
    localId: params.localId,
    resumeInactiveSession: true,
    permissionModeOverride: params.permissionMode,
  });
  return result.ok ? { ok: true } : { ok: false, code: result.code };
}

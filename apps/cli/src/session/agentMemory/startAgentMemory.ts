import { readAgentIdentityFromEnvironment } from '@/agent/runtime/agentIdentityEnvironment';
import { createAccountKvHttpTransport, type AccountKvTransport } from '@/api/kv/accountKvHttpTransport';
import { resolveAccountScopedCryptoMaterial, type Credentials } from '@/persistence';
import { describeSessionForPresence, reportPresenceFailure } from '@/session/presence/startSessionPresence';

import { AgentMemory } from './agentMemory';

export type AgentMemoryWatchedSession = Readonly<{
  sessionId: string;
  on: (event: 'local-presence', listener: (presence: Readonly<{ thinking: boolean }>) => void) => unknown;
  off: (event: 'local-presence', listener: (presence: Readonly<{ thinking: boolean }>) => void) => unknown;
  getMetadataSnapshot?: () => unknown;
}>;

type Entry = { memory: AgentMemory; detach: () => void };

/** One memory per session id; a client swap (offline → real, reconnect) keeps the same one. */
const memoryBySessionId = new Map<string, Entry>();

/**
 * When this runner works as an agent (identity handed over at spawn), give it the agent's shared
 * memory and keep its `now` fresh at the start of every turn.
 */
export function startAgentMemory(
  session: AgentMemoryWatchedSession,
  credentials: Credentials,
  deps: Readonly<{ transport?: AccountKvTransport; env?: NodeJS.ProcessEnv }> = {},
): AgentMemory | null {
  const sessionId = session.sessionId;
  const identity = readAgentIdentityFromEnvironment(deps.env);
  if (!identity || !sessionId || sessionId.startsWith('offline-') || !credentials.encryption) return null;

  const previous = memoryBySessionId.get(sessionId);
  previous?.detach();
  const memory = previous?.memory ?? new AgentMemory({
    agentId: identity.id,
    sessionId,
    transport: deps.transport ?? createAccountKvHttpTransport({ token: credentials.token }),
    material: resolveAccountScopedCryptoMaterial(credentials),
    describeSelf: () => {
      const self = describeSessionForPresence(session.getMetadataSnapshot?.() ?? null);
      return {
        ...(self.task ? { title: self.task } : {}),
        ...(self.directory ? { directory: self.directory } : {}),
        ...(self.host ? { host: self.host } : {}),
      };
    },
  });

  let working = false;
  const onLocalPresence = (snapshot: Readonly<{ thinking: boolean }>) => {
    const next = snapshot.thinking === true;
    if (next === working) return;
    working = next;
    if (next) void memory.touchNow().catch(reportPresenceFailure('agent now'));
  };
  session.on('local-presence', onLocalPresence);
  memoryBySessionId.set(sessionId, { memory, detach: () => session.off('local-presence', onLocalPresence) });
  return memory;
}

export function getAgentMemory(sessionId: string | null | undefined): AgentMemory | null {
  return sessionId ? memoryBySessionId.get(sessionId)?.memory ?? null : null;
}

export function resetAgentMemoryForTests(): void {
  for (const entry of memoryBySessionId.values()) entry.detach();
  memoryBySessionId.clear();
}

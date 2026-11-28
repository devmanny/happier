import { readAgentIdentityFromEnvironment } from '@/agent/runtime/agentIdentityEnvironment';
import { createAccountKvHttpTransport, type AccountKvTransport } from '@/api/kv/accountKvHttpTransport';
import { resolveAccountScopedCryptoMaterial, type Credentials } from '@/persistence';

import { reportPresenceFailure } from '@/session/presence/startSessionPresence';

import { AgentTaskStore } from './agentTaskStore';
import type { AgentTaskCaller } from './runAgentTaskTool';

export type AgentTasksContext = Readonly<{
  store: AgentTaskStore;
  caller: AgentTaskCaller;
  /** Resolves once the turn-end bookkeeping started so far has finished. */
  settled: () => Promise<void>;
}>;

type TaskWatchedSession = Readonly<{
  sessionId: string;
  on?: (event: 'local-presence', listener: (presence: Readonly<{ thinking: boolean }>) => void) => unknown;
}>;

/** One task context per session id this runner works for; a client swap keeps it. */
const contextBySessionId = new Map<string, AgentTasksContext>();

/** Every runner can leave tasks; one working as an agent also gets its board each turn. */
export function startAgentTasks(
  session: TaskWatchedSession,
  credentials: Credentials,
  deps: Readonly<{ transport?: AccountKvTransport; env?: NodeJS.ProcessEnv }> = {},
): AgentTasksContext | null {
  const sessionId = session.sessionId;
  if (!sessionId || sessionId.startsWith('offline-') || !credentials.encryption) return null;
  const existing = contextBySessionId.get(sessionId);
  if (existing) return existing;
  const identity = readAgentIdentityFromEnvironment(deps.env);
  const store = new AgentTaskStore({
    transport: deps.transport ?? createAccountKvHttpTransport({ token: credentials.token }),
    material: resolveAccountScopedCryptoMaterial(credentials),
  });
  let pending: Promise<void> = Promise.resolve();
  const context: AgentTasksContext = {
    store,
    caller: {
      sessionId,
      agent: identity ? { id: identity.id, name: identity.name, ...(identity.emoji ? { emoji: identity.emoji } : {}) } : null,
    },
    settled: () => pending,
  };
  // A thread working a recurring task's occurrence (an agent's, or a session it was assigned to)
  // completes it when its turn ends.
  if (session.on) {
    let working = false;
    session.on('local-presence', (presence) => {
      const next = presence.thinking === true;
      if (next === working) return;
      working = next;
      if (next) return;
      pending = pending
        .then(() => store.completeOccurrencesInThread(sessionId))
        .catch(reportPresenceFailure('complete task occurrence'));
    });
  }
  contextBySessionId.set(sessionId, context);
  return context;
}

export function getAgentTasks(sessionId: string | null | undefined): AgentTasksContext | null {
  return sessionId ? contextBySessionId.get(sessionId) ?? null : null;
}

export function resetAgentTasksForTests(): void {
  contextBySessionId.clear();
}

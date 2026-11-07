import { readAgentIdentityFromEnvironment } from '@/agent/runtime/agentIdentityEnvironment';
import { createAccountKvHttpTransport, type AccountKvTransport } from '@/api/kv/accountKvHttpTransport';
import { resolveAccountScopedCryptoMaterial, type Credentials } from '@/persistence';

import { AgentTaskStore } from './agentTaskStore';
import type { AgentTaskCaller } from './runAgentTaskTool';

export type AgentTasksContext = Readonly<{ store: AgentTaskStore; caller: AgentTaskCaller }>;

/** One task context per session id this runner works for; a client swap keeps it. */
const contextBySessionId = new Map<string, AgentTasksContext>();

/** Every runner can leave tasks; one working as an agent also gets its board each turn. */
export function startAgentTasks(
  session: Readonly<{ sessionId: string }>,
  credentials: Credentials,
  deps: Readonly<{ transport?: AccountKvTransport; env?: NodeJS.ProcessEnv }> = {},
): AgentTasksContext | null {
  const sessionId = session.sessionId;
  if (!sessionId || sessionId.startsWith('offline-') || !credentials.encryption) return null;
  const existing = contextBySessionId.get(sessionId);
  if (existing) return existing;
  const identity = readAgentIdentityFromEnvironment(deps.env);
  const context: AgentTasksContext = {
    store: new AgentTaskStore({
      transport: deps.transport ?? createAccountKvHttpTransport({ token: credentials.token }),
      material: resolveAccountScopedCryptoMaterial(credentials),
    }),
    caller: {
      sessionId,
      agent: identity ? { id: identity.id, name: identity.name, ...(identity.emoji ? { emoji: identity.emoji } : {}) } : null,
    },
  };
  contextBySessionId.set(sessionId, context);
  return context;
}

export function getAgentTasks(sessionId: string | null | undefined): AgentTasksContext | null {
  return sessionId ? contextBySessionId.get(sessionId) ?? null : null;
}

export function resetAgentTasksForTests(): void {
  contextBySessionId.clear();
}

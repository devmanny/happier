import { readAgentIdentityFromEnvironment } from '@/agent/runtime/agentIdentityEnvironment';
import { createAccountKvHttpTransport, type AccountKvTransport } from '@/api/kv/accountKvHttpTransport';
import { resolveAccountScopedCryptoMaterial, type Credentials } from '@/persistence';

import { AgentRoomStore } from './agentRoomStore';
import type { AgentRoomCaller } from './runAgentRoomTool';

export type AgentRoomsContext = Readonly<{
  store: AgentRoomStore;
  caller: AgentRoomCaller;
}>;

/** One rooms context per session id this runner works for; a client swap keeps it. */
const contextBySessionId = new Map<string, AgentRoomsContext>();

/** Every runner of an encrypted account can read the rooms its agent is a member of. */
export function startAgentRooms(
  session: Readonly<{ sessionId: string }>,
  credentials: Credentials,
  deps: Readonly<{ transport?: AccountKvTransport; env?: NodeJS.ProcessEnv }> = {},
): AgentRoomsContext | null {
  const sessionId = session.sessionId;
  if (!sessionId || sessionId.startsWith('offline-') || !credentials.encryption) return null;
  const existing = contextBySessionId.get(sessionId);
  if (existing) return existing;
  const identity = readAgentIdentityFromEnvironment(deps.env);
  const context: AgentRoomsContext = {
    store: new AgentRoomStore({
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

export function getAgentRooms(sessionId: string | null | undefined): AgentRoomsContext | null {
  return sessionId ? contextBySessionId.get(sessionId) ?? null : null;
}

export function resetAgentRoomsForTests(): void {
  contextBySessionId.clear();
}

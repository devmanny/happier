import { parseRoomDeliveryLocalId } from '@happier-dev/protocol';

import { readAgentIdentityFromEnvironment } from '@/agent/runtime/agentIdentityEnvironment';
import { createAccountKvHttpTransport, type AccountKvTransport } from '@/api/kv/accountKvHttpTransport';
import { resolveAccountScopedCryptoMaterial, type Credentials } from '@/persistence';
import { readTurnReplyAfterLocalId, type TurnReply } from '@/session/services/readTurnReplyAfterLocalId';
import { getActiveAccountSettingsSnapshot } from '@/settings/accountSettings/activeAccountSettingsSnapshot';
import { logger } from '@/ui/logger';

import { AgentRoomStore } from './agentRoomStore';
import { completeRoomTurn, type RoomPushSender } from './completeRoomTurn';
import type { AgentRoomCaller } from './runAgentRoomTool';

export type AgentRoomsContext = Readonly<{
  store: AgentRoomStore;
  caller: AgentRoomCaller;
}>;

type RoomWatchedSession = Readonly<{
  sessionId: string;
  on?: (event: 'provider-input-delivered', listener: (event: Readonly<{ localId: string }>) => void) => unknown;
}>;

type RoomRunner = Readonly<{
  context: AgentRoomsContext;
  /** Posts the reply of the room delivery this runner's current turn worked, if any. */
  turnReady: () => Promise<void>;
}>;

/** One rooms runner per session id this process works for; a client swap keeps it. */
const runnerBySessionId = new Map<string, RoomRunner>();

export function pushEnabledInAccountSettings(): boolean {
  return getActiveAccountSettingsSnapshot()?.settings?.notificationsSettingsV1?.pushEnabled !== false;
}

/**
 * Every runner of an encrypted account can read the rooms its agent is a member of. A runner
 * working as an agent also ends its room turns: a delivery the daemon sent it (localId `room:…`)
 * is remembered when it reaches the provider, and when that turn is ready its final text is posted
 * to the room as the agent's reply.
 */
export function startAgentRooms(
  session: RoomWatchedSession,
  credentials: Credentials,
  deps: Readonly<{
    transport?: AccountKvTransport;
    env?: NodeJS.ProcessEnv;
    push?: RoomPushSender | null;
    pushEnabled?: () => boolean;
    readTurnReply?: (sessionId: string, localId: string) => Promise<TurnReply | null>;
  }> = {},
): AgentRoomsContext | null {
  const sessionId = session.sessionId;
  if (!sessionId || sessionId.startsWith('offline-') || !credentials.encryption) return null;
  const existing = runnerBySessionId.get(sessionId);
  if (existing) return existing.context;
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
  const readTurnReply = deps.readTurnReply
    ?? ((id: string, localId: string) => readTurnReplyAfterLocalId({ credentials, sessionId: id, localId }));

  let delivery: Readonly<{ roomId: string; agentId: string; localId: string }> | null = null;
  if (identity && session.on) {
    session.on('provider-input-delivered', ({ localId }) => {
      const parsed = parseRoomDeliveryLocalId(localId);
      if (parsed && parsed.agentId === identity.id) delivery = { roomId: parsed.roomId, agentId: parsed.agentId, localId };
    });
  }

  const turnReady = async () => {
    const current = delivery;
    if (!current || !identity) return;
    delivery = null;
    const reply = await readTurnReply(sessionId, current.localId);
    // Not in the transcript yet: the daemon finishes it from the transcript later.
    if (!reply) return;
    await completeRoomTurn({
      store: context.store,
      delivery: current,
      author: { kind: 'agent', agentId: identity.id, name: identity.name, ...(identity.emoji ? { emoji: identity.emoji } : {}), sessionId },
      reply: { finished: true, text: reply.text },
      push: deps.push ?? null,
      pushEnabled: deps.pushEnabled ?? pushEnabledInAccountSettings,
    });
  };
  runnerBySessionId.set(sessionId, { context, turnReady });
  return context;
}

export function getAgentRooms(sessionId: string | null | undefined): AgentRoomsContext | null {
  return sessionId ? runnerBySessionId.get(sessionId)?.context ?? null : null;
}

/** Called when a turn of `sessionId` is ready (its transcript flushed); never throws. */
export async function notifyRoomTurnReady(sessionId: string | null | undefined): Promise<void> {
  const runner = sessionId ? runnerBySessionId.get(sessionId) : undefined;
  if (!runner) return;
  try {
    await runner.turnReady();
  } catch (error) {
    logger.warn('[ROOMS] Could not post a room turn\'s reply; the daemon will finish it', {
      sessionId,
      error: error instanceof Error ? error.message : String(error),
    });
  }
}

export function resetAgentRoomsForTests(): void {
  runnerBySessionId.clear();
}

import { parseRoomDeliveryLocalId } from '@happier-dev/protocol';

import { readAgentIdentityFromEnvironment } from '@/agent/runtime/agentIdentityEnvironment';
import { createAccountKvHttpTransport, type AccountKvTransport } from '@/api/kv/accountKvHttpTransport';
import { resolveAccountScopedCryptoMaterial, type Credentials } from '@/persistence';
import { readTurnReplyAfterLocalId, type TurnReply } from '@/session/services/readTurnReplyAfterLocalId';
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
  /** See `notifyRoomTurnReady`. */
  turnReady: () => Promise<boolean> | null;
}>;

/** One rooms runner per session id this process works for; a client swap keeps it. */
const runnerBySessionId = new Map<string, RoomRunner>();

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
    readTurnReply?: (sessionId: string, localId: string) => Promise<TurnReply | 'thread_gone' | null>;
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
  // What reached the provider last: a ready turn answered the room delivery only when it is that delivery.
  let lastDeliveredLocalId: string | null = null;
  if (identity && session.on) {
    session.on('provider-input-delivered', ({ localId }) => {
      lastDeliveredLocalId = localId;
      const parsed = parseRoomDeliveryLocalId(localId);
      if (parsed && parsed.agentId === identity.id) delivery = { roomId: parsed.roomId, agentId: parsed.agentId, localId };
    });
  }

  const turnReady = () => {
    const current = delivery;
    if (!current || !identity) return null;
    delivery = null;
    const posting = (async () => {
      const reply = await readTurnReply(sessionId, current.localId);
      // Not in the transcript yet: the daemon finishes it from the transcript later, so the turn's own
      // notice still goes. Its thread gone: the daemon delivers it again to a new one, whose reply is told.
      if (!reply) return false;
      if (reply === 'thread_gone') return true;
      // Finished here, or already by the daemon: either way the room told the user, unless the turn
      // wrote no final text, so the room has no reply to tell.
      const outcome = await completeRoomTurn({
        store: context.store,
        delivery: current,
        author: { kind: 'agent', agentId: identity.id, name: identity.name, ...(identity.emoji ? { emoji: identity.emoji } : {}), sessionId },
        reply: { finished: true, text: reply.text },
        push: deps.push ?? null,
      });
      return outcome !== 'no_reply';
    })().catch((error: unknown) => {
      logger.warn('[ROOMS] Could not post a room turn\'s reply; the daemon will finish it', {
        sessionId,
        error: error instanceof Error ? error.message : String(error),
      });
      return false;
    });
    // A room turn that ended without a ready of its own (it went on with what the user typed meanwhile)
    // is posted at the next ready, which belongs to that later turn: it keeps its own notice.
    return lastDeliveredLocalId === current.localId ? posting : null;
  };
  runnerBySessionId.set(sessionId, { context, turnReady });
  return context;
}

export function getAgentRooms(sessionId: string | null | undefined): AgentRoomsContext | null {
  return sessionId ? runnerBySessionId.get(sessionId)?.context ?? null : null;
}

/**
 * Called when a turn of `sessionId` is ready (its transcript flushed); posts the reply of the room
 * delivery this runner's turns worked, if any. When the ready turn is the one that delivery started,
 * returns that posting (never rejects), resolving to whether the room took over the turn's notice:
 * then the room's own notice (`completeRoomTurn`, or the daemon's when it finishes the turn) is that
 * reply's only one, and the caller sends no turn-finished notification. False when no reply was
 * posted (not in the transcript yet, the turn wrote no final text, or the post failed), so the
 * caller still sends it. Null for any other turn.
 */
export function notifyRoomTurnReady(sessionId: string | null | undefined): Promise<boolean> | null {
  return sessionId ? runnerBySessionId.get(sessionId)?.turnReady() ?? null : null;
}

export function resetAgentRoomsForTests(): void {
  runnerBySessionId.clear();
}

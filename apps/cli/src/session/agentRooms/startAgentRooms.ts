import { parseRoomDeliveryLocalId } from '@happier-dev/protocol';

import { readAgentIdentityFromEnvironment } from '@/agent/runtime/agentIdentityEnvironment';
import { createAccountKvHttpTransport, type AccountKvTransport } from '@/api/kv/accountKvHttpTransport';
import { resolveAccountScopedCryptoMaterial, type Credentials } from '@/persistence';
import { readTurnReplyAfterLocalId, type TurnReply } from '@/session/services/readTurnReplyAfterLocalId';
import { logger } from '@/ui/logger';

import { AgentRoomStore } from './agentRoomStore';
import { settleRoomTurn, type RoomPushSender } from './completeRoomTurn';
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

/** The room delivery a runner's turns work: the one that reached the provider last. */
type TrackedRoomDelivery = Readonly<{ roomId: string; agentId: string; localId: string }>;

/**
 * Every runner of an encrypted account can read the rooms its agent is a member of. A runner
 * working as an agent also ends its room turns: a delivery the daemon sent it (localId `room.…`)
 * is tracked from when it reaches the provider, and at each ready what its thread's transcript
 * shows ended is posted to the room as the agent's reply (`settleRoomTurn`, with the delivery a
 * Steer Now was sent past). It is tracked until the seat's delivery in flight is finished, so one
 * whose turn hasn't reached the transcript yet is settled at a later ready.
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

  // A new object per delivery, so a settle clears only the tracking it read.
  let tracked: TrackedRoomDelivery | null = null;
  // What reached the provider last: a ready turn answered the room delivery only when it is that delivery.
  let lastDeliveredLocalId: string | null = null;
  if (identity && session.on) {
    session.on('provider-input-delivered', ({ localId }) => {
      lastDeliveredLocalId = localId;
      const parsed = parseRoomDeliveryLocalId(localId);
      if (parsed && parsed.agentId === identity.id) tracked = { roomId: parsed.roomId, agentId: parsed.agentId, localId };
    });
  }

  /** Whether the room told the user about this ready's turn (see `notifyRoomTurnReady`). */
  const settle = async (current: TrackedRoomDelivery, agent: NonNullable<typeof identity>): Promise<boolean> => {
    const stopTracking = () => {
      if (tracked === current) tracked = null;
    };
    const inFlight = (await context.store.getSeats(current.roomId, [current.agentId])).get(current.agentId)?.seat.inFlight;
    // The tracked delivery was finished elsewhere (by the daemon, which told the user) or its thread
    // is gone; a newer delivery in flight is settled once it reaches this runner.
    if (!inFlight || (inFlight.localId !== current.localId && inFlight.steers?.localId !== current.localId)) {
      stopTracking();
      return true;
    }
    const settled = await settleRoomTurn({
      store: context.store,
      delivery: { roomId: current.roomId, agentId: current.agentId },
      inFlight,
      sessionId,
      author: { kind: 'agent', agentId: agent.id, name: agent.name, ...(agent.emoji ? { emoji: agent.emoji } : {}), sessionId },
      readTurnReply,
      push: deps.push ?? null,
      turnEnded: true,
    });
    if (settled.turn === 'finished' || settled.turn === 'thread_gone') stopTracking();
    // Its thread gone: the daemon delivers it again to a new one, whose reply is told. Otherwise the
    // room told the user when a reply was posted here (or another writer had ended that turn); not
    // when the turn wrote no final text or isn't in the transcript yet, so the turn's own notice goes.
    return settled.turn === 'thread_gone' || settled.replied;
  };

  // Readies settle one at a time, so the turn a Steer Now was sent past is posted before its own.
  let settling: Promise<unknown> = Promise.resolve();
  const turnReady = () => {
    const current = tracked;
    if (!current || !identity) return null;
    const posting = settling.then(() => settle(current, identity)).catch((error: unknown) => {
      logger.warn('[ROOMS] Could not post a room turn\'s reply; the daemon will finish it', {
        sessionId,
        error: error instanceof Error ? error.message : String(error),
      });
      return false;
    });
    settling = posting;
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
 * Called when a turn of `sessionId` is ready (its transcript flushed); posts the replies of the room
 * delivery this runner's turns work (and of the one a Steer Now was sent past) that its transcript
 * shows ended, if any. When the ready turn is the one that delivery started, returns that posting
 * (never rejects), resolving to whether the room took over the turn's notice: then the room's own
 * notice (`completeRoomTurn`, or the daemon's when it finishes the turn) is that reply's only one,
 * and the caller sends no turn-finished notification. False when no reply was posted (not in the
 * transcript yet, the turn wrote no final text, or the post failed), so the caller still sends it.
 * Null for any other turn.
 */
export function notifyRoomTurnReady(sessionId: string | null | undefined): Promise<boolean> | null {
  return sessionId ? runnerBySessionId.get(sessionId)?.turnReady() ?? null : null;
}

export function resetAgentRoomsForTests(): void {
  runnerBySessionId.clear();
}

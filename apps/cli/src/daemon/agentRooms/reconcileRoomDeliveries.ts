import { randomUUID } from 'node:crypto';

import {
  AGENT_ROOM_MAX_AGENT_TURNS,
  agentRoomUnreadRange,
  buildRoomDeliveryPrompt,
  decideRoomDelivery,
  roomContinuationFromSeq,
  roomDeliveryLocalId,
  roomDeliveryQuotedSeqs,
  roomMemberPermissionMode,
  type AgentProfileV1,
  type AgentRoomMember,
  type AgentRoomSeatV1,
  type AgentRoomV1,
  type RoomDeliveryContinuation,
} from '@happier-dev/protocol';

import { spawnAsAgent, type AgentThreadSpawn } from '@/daemon/agents/agentThreadSpawn';
import type { AgentRoomStore } from '@/session/agentRooms/agentRoomStore';
import { completeRoomTurn, type RoomPushSender } from '@/session/agentRooms/completeRoomTurn';
import type { TurnReply } from '@/session/services/readTurnReplyAfterLocalId';
import { logger } from '@/ui/logger';

export type RoomDeliveryDeps = Readonly<{
  store: AgentRoomStore;
  /** This daemon's machine: it delivers to the members that work here. */
  machineId: string;
  readAgentProfile: (agentId: string) => Promise<AgentProfileV1 | null>;
  /** Opens the member's thread with the delivery as its first message, sent with `localId`. */
  startThread: (spawn: AgentThreadSpawn, firstInput: Readonly<{ text: string; localId: string }>) => Promise<
    Readonly<{ ok: true; sessionId: string }> | Readonly<{ ok: false; code: string; message: string }>
  >;
  /** Sends the delivery to the member's thread (resuming it if inactive) through the canonical send path. */
  sendToThread: (sessionId: string, text: string, localId: string, permissionMode: string) => Promise<
    Readonly<{ ok: true }> | Readonly<{ ok: false; code: string }>
  >;
  /**
   * The reply of the turn the delivery sent with `localId` started, from the thread's transcript;
   * `'thread_gone'` when that turn can never finish (the thread was deleted, or archived mid-turn).
   */
  readTurnReply: (sessionId: string, localId: string) => Promise<TurnReply | 'thread_gone' | null>;
  push: RoomPushSender | null;
  newNonce?: () => string;
}>;

/** The thread is gone: a new one is opened for the member. */
const GONE_THREAD_CODES = new Set(['session_not_found', 'session_archived']);

type Seat = Readonly<{ seat: AgentRoomSeatV1; version: number }>;

/**
 * Brings one room's deliveries up to date for the members that work on this machine (each daemon
 * delivers to its own machine's members, so a room may span machines without a coordinator):
 *
 * - a member whose turn is in flight gets nothing new; once its thread's transcript shows that turn
 *   finished (its runner normally posts the reply itself) the turn is finished here. When that
 *   thread is gone mid-turn, the delivery is dropped without moving the marker, so what it carried
 *   goes again, in this same run, to a new thread with a new localId (a late reply of the old one
 *   can't finish it);
 * - a delivery that could not be sent is sent again with the same localId, so it lands once;
 * - otherwise, when `decideRoomDelivery` says so, everything the member hadn't read is sent to its
 *   thread in the room (opened in its folder, as its agent, the first time; a new thread for a
 *   member that had read the room gets the room so far, see `buildRoomDeliveryPrompt`).
 *
 * Every step is a versioned write on the member's seat, so a concurrent run changes nothing twice;
 * the room's KV events run it again. Seats are read before messages and a delivery is claimed with
 * a CAS on the seat version read, so a seat written back unchanged by the app when it withdraws or
 * edits a message the member hasn't got (docs/api.md) makes the claim fail, and the next run reads
 * the room as it is then; a deleted message is simply not there.
 */
export async function reconcileRoomDeliveries(roomId: string, deps: RoomDeliveryDeps): Promise<void> {
  const current = await deps.store.getRoom(roomId);
  if (!current) return;
  const room = current.room;
  const members = room.members.filter((member) => member.machineId === deps.machineId);
  if (members.length === 0) return;
  const seats = await deps.store.getSeats(roomId, members.map((member) => member.agentId));
  for (const member of members) {
    try {
      await reconcileMember(room, member, seats.get(member.agentId) ?? null, deps);
    } catch (error) {
      logger.warn('[ROOMS] Room delivery failed (retried on the room\'s next change)', {
        roomId, agentId: member.agentId, error: error instanceof Error ? error.message : String(error),
      });
    }
  }
}

async function reconcileMember(room: AgentRoomV1, member: AgentRoomMember, read: Seat | null, deps: RoomDeliveryDeps): Promise<void> {
  let seat = read;
  let goneSessionId: string | undefined;
  const inFlight = seat?.seat.inFlight;
  if (seat && inFlight) {
    if (!inFlight.sent) {
      await send(room, member, seat.seat, inFlight.localId, inFlight.throughSeq, deps);
      return;
    }
    const sessionId = seat.seat.sessionId;
    if (!sessionId) return;
    const reply = await deps.readTurnReply(sessionId, inFlight.localId);
    if (!reply) return;
    if (reply !== 'thread_gone') {
      await completeRoomTurn({
        store: deps.store,
        delivery: { roomId: room.id, agentId: member.agentId, localId: inFlight.localId },
        author: {
          kind: 'agent', agentId: member.agentId, sessionId,
          ...(member.name ? { name: member.name } : {}), ...(member.emoji ? { emoji: member.emoji } : {}),
        },
        reply,
        push: deps.push,
      });
      return;
    }
    logger.warn('[ROOMS] A member\'s room thread is gone mid-turn; its delivery goes to a new thread', { roomId: room.id, agentId: member.agentId, sessionId });
    await deps.store.updateSeat(room.id, member.agentId, (latest) => {
      if (latest.inFlight?.localId !== inFlight.localId) return latest;
      const { inFlight: _dropped, sessionId: _gone, ...rest } = latest;
      return rest;
    });
    goneSessionId = sessionId;
    seat = (await deps.store.getSeats(room.id, [member.agentId])).get(member.agentId) ?? null;
  }

  const range = agentRoomUnreadRange(room, seat?.seat ?? null);
  if (!range) return;
  const messages = await deps.store.readMessages(room.id, { fromSeq: range.fromSeq - AGENT_ROOM_MAX_AGENT_TURNS + 1, toSeq: range.toSeq });
  const decision = decideRoomDelivery({ room, member, seat: seat?.seat ?? null, messages });
  if (decision.kind !== 'deliver') return;
  const localId = roomDeliveryLocalId({ roomId: room.id, agentId: member.agentId, nonce: deps.newNonce?.() ?? randomUUID().slice(0, 8) });
  if (!await deps.store.startDelivery(room.id, member.agentId, { localId, throughSeq: decision.toSeq }, seat)) return;
  const claimed = seat?.seat ?? { v: 1 as const, roomId: room.id, agentId: member.agentId, readThroughSeq: 0, updatedAt: 0 };
  await send(room, member, claimed, localId, decision.toSeq, deps, messages, goneSessionId);
}

/**
 * Sends the delivery (in flight with `localId`) to the member's thread, opening one when it has none
 * (or its thread is gone). A new thread for a member that had read the room gets the room so far,
 * with the thread before it (`goneSessionId`, or the one found gone here). The messages it answers
 * are read too, so the member sees what the user quoted.
 */
async function send(
  room: AgentRoomV1,
  member: AgentRoomMember,
  seat: AgentRoomSeatV1,
  localId: string,
  throughSeq: number,
  deps: RoomDeliveryDeps,
  known?: Parameters<typeof buildRoomDeliveryPrompt>[0]['messages'],
  goneSessionId?: string,
): Promise<void> {
  const fromSeq = seat.readThroughSeq + 1;
  const prompt = async (continuation?: RoomDeliveryContinuation) => {
    const read = continuation || !known
      ? await deps.store.readMessages(room.id, { fromSeq: continuation ? roomContinuationFromSeq(throughSeq) : fromSeq, toSeq: throughSeq })
      : known;
    const range = { member, fromSeq, toSeq: throughSeq, ...(continuation ? { continuation } : {}) };
    const quoted = roomDeliveryQuotedSeqs({ ...range, messages: read });
    const messages = quoted.length > 0 ? [...read, ...await deps.store.readMessagesAt(room.id, quoted)] : read;
    return buildRoomDeliveryPrompt({ room, ...range, messages });
  };
  const permissionMode = roomMemberPermissionMode(member);
  const forThisDelivery = (change: (latest: AgentRoomSeatV1) => AgentRoomSeatV1) =>
    deps.store.updateSeat(room.id, member.agentId, (latest) => (latest.inFlight?.localId === localId ? change(latest) : latest));

  let previousSessionId = goneSessionId;
  if (seat.sessionId) {
    const sent = await deps.sendToThread(seat.sessionId, await prompt(), localId, permissionMode);
    if (sent.ok) {
      await forThisDelivery((latest) => ({ ...latest, inFlight: { ...latest.inFlight!, sent: true } }));
      return;
    }
    if (!GONE_THREAD_CODES.has(sent.code)) {
      logger.warn('[ROOMS] Could not send a room delivery (sent again on the room\'s next change)', { roomId: room.id, agentId: member.agentId, code: sent.code });
      return;
    }
    previousSessionId = seat.sessionId;
    await forThisDelivery(({ sessionId: _gone, ...latest }) => latest);
  }

  const profile = await deps.readAgentProfile(member.agentId);
  if (!profile) {
    logger.warn('[ROOMS] A room member has no agent profile; its delivery is dropped', { roomId: room.id, agentId: member.agentId });
    await forThisDelivery(({ inFlight: _dropped, ...latest }) => latest);
    return;
  }
  const text = await prompt(seat.readThroughSeq > 0 ? { ...(previousSessionId ? { previousSessionId } : {}) } : undefined);
  const started = await deps.startThread(spawnAsAgent(profile, member.directory, permissionMode), { text, localId });
  if (!started.ok) {
    logger.warn('[ROOMS] Could not open a member\'s room thread (tried again on the room\'s next change)', {
      roomId: room.id, agentId: member.agentId, code: started.code, message: started.message,
    });
    return;
  }
  await forThisDelivery((latest) => ({ ...latest, sessionId: started.sessionId, inFlight: { ...latest.inFlight!, sent: true } }));
}

import { randomUUID } from 'node:crypto';

import {
  AGENT_ROOM_MAX_AGENT_TURNS,
  agentRoomUnreadRange,
  buildRoomDeliveryPrompt,
  decideRoomDelivery,
  roomDeliveryLocalId,
  roomDeliveryQuotedSeqs,
  roomMemberPermissionMode,
  type AgentProfileV1,
  type AgentRoomMember,
  type AgentRoomSeatV1,
  type AgentRoomV1,
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
  /** The reply of the turn the delivery sent with `localId` started, from the thread's transcript. */
  readTurnReply: (sessionId: string, localId: string) => Promise<TurnReply | null>;
  push: RoomPushSender | null;
  pushEnabled: () => boolean;
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
 *   finished (its runner normally posts the reply itself) the turn is finished here;
 * - a delivery that could not be sent is sent again with the same localId, so it lands once;
 * - otherwise, when `decideRoomDelivery` says so, everything the member hadn't read is sent to its
 *   thread in the room (opened in its folder, as its agent, the first time).
 *
 * Every step is a versioned write on the member's seat, so a concurrent run changes nothing twice;
 * the room's KV events run it again.
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

async function reconcileMember(room: AgentRoomV1, member: AgentRoomMember, seat: Seat | null, deps: RoomDeliveryDeps): Promise<void> {
  const inFlight = seat?.seat.inFlight;
  if (seat && inFlight) {
    if (!inFlight.sent) {
      await send(room, member, seat.seat, inFlight.localId, inFlight.throughSeq, deps);
      return;
    }
    if (!seat.seat.sessionId) return;
    const reply = await deps.readTurnReply(seat.seat.sessionId, inFlight.localId);
    if (!reply) return;
    await completeRoomTurn({
      store: deps.store,
      delivery: { roomId: room.id, agentId: member.agentId, localId: inFlight.localId },
      author: {
        kind: 'agent', agentId: member.agentId, sessionId: seat.seat.sessionId,
        ...(member.name ? { name: member.name } : {}), ...(member.emoji ? { emoji: member.emoji } : {}),
      },
      reply,
      push: deps.push,
      pushEnabled: deps.pushEnabled,
    });
    return;
  }

  const range = agentRoomUnreadRange(room, seat?.seat ?? null);
  if (!range) return;
  const messages = await deps.store.readMessages(room.id, { fromSeq: range.fromSeq - AGENT_ROOM_MAX_AGENT_TURNS + 1, toSeq: range.toSeq });
  const decision = decideRoomDelivery({ room, member, seat: seat?.seat ?? null, messages });
  if (decision.kind !== 'deliver') return;
  const localId = roomDeliveryLocalId({ roomId: room.id, agentId: member.agentId, nonce: deps.newNonce?.() ?? randomUUID().slice(0, 8) });
  if (!await deps.store.startDelivery(room.id, member.agentId, { localId, throughSeq: decision.toSeq }, seat)) return;
  const claimed = seat?.seat ?? { v: 1 as const, roomId: room.id, agentId: member.agentId, readThroughSeq: 0, updatedAt: 0 };
  await send(room, member, claimed, localId, decision.toSeq, deps, messages);
}

/**
 * Sends the delivery (in flight with `localId`) to the member's thread, opening one when it has none.
 * The messages it answers are read too, so the member sees what the user quoted.
 */
async function send(
  room: AgentRoomV1,
  member: AgentRoomMember,
  seat: AgentRoomSeatV1,
  localId: string,
  throughSeq: number,
  deps: RoomDeliveryDeps,
  known?: Parameters<typeof buildRoomDeliveryPrompt>[0]['messages'],
): Promise<void> {
  const fromSeq = seat.readThroughSeq + 1;
  const unread = known ?? await deps.store.readMessages(room.id, { fromSeq, toSeq: throughSeq });
  const quoted = roomDeliveryQuotedSeqs({ member, messages: unread, fromSeq, toSeq: throughSeq });
  const messages = quoted.length > 0 ? [...unread, ...await deps.store.readMessagesAt(room.id, quoted)] : unread;
  const text = buildRoomDeliveryPrompt({ room, member, messages, fromSeq, toSeq: throughSeq });
  const permissionMode = roomMemberPermissionMode(member);
  const forThisDelivery = (change: (latest: AgentRoomSeatV1) => AgentRoomSeatV1) =>
    deps.store.updateSeat(room.id, member.agentId, (latest) => (latest.inFlight?.localId === localId ? change(latest) : latest));

  if (seat.sessionId) {
    const sent = await deps.sendToThread(seat.sessionId, text, localId, permissionMode);
    if (sent.ok) {
      await forThisDelivery((latest) => ({ ...latest, inFlight: { ...latest.inFlight!, sent: true } }));
      return;
    }
    if (!GONE_THREAD_CODES.has(sent.code)) {
      logger.warn('[ROOMS] Could not send a room delivery (sent again on the room\'s next change)', { roomId: room.id, agentId: member.agentId, code: sent.code });
      return;
    }
    await forThisDelivery(({ sessionId: _gone, ...latest }) => latest);
  }

  const profile = await deps.readAgentProfile(member.agentId);
  if (!profile) {
    logger.warn('[ROOMS] A room member has no agent profile; its delivery is dropped', { roomId: room.id, agentId: member.agentId });
    await forThisDelivery(({ inFlight: _dropped, ...latest }) => latest);
    return;
  }
  const started = await deps.startThread(spawnAsAgent(profile, member.directory, permissionMode), { text, localId });
  if (!started.ok) {
    logger.warn('[ROOMS] Could not open a member\'s room thread (tried again on the room\'s next change)', {
      roomId: room.id, agentId: member.agentId, code: started.code, message: started.message,
    });
    return;
  }
  await forThisDelivery((latest) => ({ ...latest, sessionId: started.sessionId, inFlight: { ...latest.inFlight!, sent: true } }));
}

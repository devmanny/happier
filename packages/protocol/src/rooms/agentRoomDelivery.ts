import { parseSessionPermissionModeAlias, type SessionPermissionMode } from '../sessionMetadata/sessionPermissionModes.js';
import {
  agentRoomUnreadRange,
  formatRoomMessages,
  resolveRoomMentions,
  roomAnswerNote,
  roomMessageAuthorLabel,
  roomUserLabel,
  type AgentRoomMember,
  type AgentRoomMessageV1,
  type AgentRoomSeatV1,
  type AgentRoomV1,
} from './agentRoom.js';

/**
 * How a room's messages reach its members (the daemon of each member's machine delivers them):
 * a member mentioned with `@` gets everything it hasn't read, in one message to its thread in the
 * room; its turn's final text is posted back as its reply, and its marker moves to what it got. A
 * new thread for a member that had read the room before (its thread was archived or deleted) also
 * gets the room so far, its own replies included, so the chat goes on where it was.
 */

/** At most this many agent turns in a row without the user: the brake. */
export const AGENT_ROOM_MAX_AGENT_TURNS = 6;

/** A long backlog is cut: the newest in full, one line each for the ones before, the rest counted. */
export const ROOM_DELIVERY_FULL_MESSAGES = 15;
export const ROOM_DELIVERY_LINE_MESSAGES = 50;
export const ROOM_DELIVERY_LINE_CHARS = 160;

export type RoomDeliveryDecision =
  | Readonly<{ kind: 'deliver'; fromSeq: number; toSeq: number }>
  | Readonly<{ kind: 'wait'; reason: 'archived' | 'busy' | 'caught_up' | 'paused' | 'not_mentioned' | 'brake' | 'needs_user' }>;

/** The member's turns run in this permission mode; YOLO unless the member says otherwise. */
export function roomMemberPermissionMode(member: AgentRoomMember): SessionPermissionMode {
  return parseSessionPermissionModeAlias(member.permissionMode ?? 'yolo') ?? 'yolo';
}

/**
 * Agent messages in a row ending at `seq`, back to the user's last message. `messages` must hold
 * the `AGENT_ROOM_MAX_AGENT_TURNS - 1` messages before `seq` for the brake to be decided.
 */
export function roomAgentStreak(messages: readonly AgentRoomMessageV1[], seq: number): number {
  const bySeq = new Map(messages.map((message) => [message.seq, message]));
  let streak = 0;
  for (let at = seq; bySeq.get(at)?.author.kind === 'agent'; at -= 1) streak += 1;
  return streak;
}

/**
 * Whether the member gets a delivery now. It does when an unread message by someone else mentions
 * it and that message may wake it: any of the user's, or an agent's while the brake allows and the
 * member may be woken by agents. A member mid-turn waits (it gets everything once the turn ends),
 * and a paused or archived room delivers nothing. `messages` holds the unread range and the
 * `AGENT_ROOM_MAX_AGENT_TURNS - 1` messages before it.
 */
export function decideRoomDelivery(params: Readonly<{
  room: AgentRoomV1;
  member: AgentRoomMember;
  seat: AgentRoomSeatV1 | null;
  messages: readonly AgentRoomMessageV1[];
}>): RoomDeliveryDecision {
  const { room, member, seat, messages } = params;
  if (room.archivedAt !== undefined) return { kind: 'wait', reason: 'archived' };
  if (seat?.inFlight) return { kind: 'wait', reason: 'busy' };
  const range = agentRoomUnreadRange(room, seat);
  if (!range) return { kind: 'wait', reason: 'caught_up' };
  if (room.pausedAt !== undefined) return { kind: 'wait', reason: 'paused' };
  const triggers = messages.filter((message) => message.seq >= range.fromSeq
    && message.seq <= range.toSeq
    && message.mentions.includes(member.agentId)
    && !(message.author.kind === 'agent' && message.author.agentId === member.agentId));
  if (triggers.length === 0) return { kind: 'wait', reason: 'not_mentioned' };
  let braked = false;
  for (const trigger of triggers) {
    if (trigger.author.kind === 'user') return { kind: 'deliver', ...range };
    if (member.wakeByAgents !== true) continue;
    if (roomAgentStreak(messages, trigger.seq) < AGENT_ROOM_MAX_AGENT_TURNS) return { kind: 'deliver', ...range };
    braked = true;
  }
  return { kind: 'wait', reason: braked ? 'brake' : 'needs_user' };
}

function oneLine(label: string, message: AgentRoomMessageV1): string {
  const line = `[#${message.seq}] ${label}${roomAnswerNote(message)}: ${message.text.replace(/\s+/g, ' ').trim()}`;
  return line.length <= ROOM_DELIVERY_LINE_CHARS ? line : `${line.slice(0, ROOM_DELIVERY_LINE_CHARS - 1)}…`;
}

/** A delivery that opens a new thread for a member whose thread before it read up to `fromSeq - 1`. */
export type RoomDeliveryContinuation = Readonly<{
  /** The thread before it, which the member can read with `mis_hilos` while it exists. */
  previousSessionId?: string;
}>;

type DeliveryRange = Readonly<{
  member: AgentRoomMember;
  messages: readonly AgentRoomMessageV1[];
  fromSeq: number;
  toSeq: number;
  continuation?: RoomDeliveryContinuation;
}>;

/**
 * The first seq a new thread's delivery (`continuation`) shows: the newest messages through `toSeq`
 * that the cut shows in full or as one line each; the ones before are only counted.
 */
export function roomContinuationFromSeq(toSeq: number): number {
  return Math.max(1, toSeq - ROOM_DELIVERY_FULL_MESSAGES - ROOM_DELIVERY_LINE_MESSAGES + 1);
}

function isOwnMessage(member: AgentRoomMember, message: AgentRoomMessageV1): boolean {
  return message.author.kind === 'agent' && message.author.agentId === member.agentId;
}

/**
 * What a delivery shows, oldest first: others' messages from `fromSeq` to `toSeq`; for a new thread,
 * every message from `roomContinuationFromSeq(toSeq)` to `toSeq`, its own included.
 */
function shownMessages(params: DeliveryRange): AgentRoomMessageV1[] {
  const fromSeq = params.continuation ? roomContinuationFromSeq(params.toSeq) : params.fromSeq;
  return [...new Map(params.messages
    .filter((message) => message.seq >= fromSeq && message.seq <= params.toSeq)
    .filter((message) => params.continuation !== undefined || !isOwnMessage(params.member, message))
    .map((message) => [message.seq, message])).values()]
    .sort((a, b) => a.seq - b.seq);
}

/**
 * The messages that the ones a delivery shows in full answer (quote) and `messages` doesn't hold:
 * the daemon reads them too, so the member sees what the user quoted, however old.
 */
export function roomDeliveryQuotedSeqs(params: DeliveryRange): number[] {
  const have = new Set(params.messages.map((message) => message.seq));
  const quoted = shownMessages(params).slice(-ROOM_DELIVERY_FULL_MESSAGES)
    .flatMap((message) => (message.replyTo && !have.has(message.replyTo.seq) ? [message.replyTo.seq] : []));
  return [...new Set(quoted)].sort((a, b) => a - b);
}

/**
 * The message a member's thread gets: who is in the room, what it hadn't read (others' messages
 * from `fromSeq` to `toSeq`, a long backlog cut down) and how its reply reaches the room. A message
 * shown in full that answers another says which, and quotes it in one line when `messages` holds
 * it (`roomDeliveryQuotedSeqs`).
 *
 * A new thread for a member that had read the room (`continuation`) gets the room so far instead,
 * its own replies included and cut the same way, with what its thread before had already answered
 * (through `fromSeq - 1`, and its own replies) apart from what is new. `messages` then needs only
 * the seqs from `roomContinuationFromSeq(toSeq)`.
 */
export function buildRoomDeliveryPrompt(params: Readonly<{ room: AgentRoomV1 }> & DeliveryRange): string {
  const { room, member, continuation } = params;
  const userLabel = roomUserLabel(room);
  const shown = shownMessages(params);
  const full = shown.slice(-ROOM_DELIVERY_FULL_MESSAGES);
  const lines = shown.slice(0, -ROOM_DELIVERY_FULL_MESSAGES).slice(-ROOM_DELIVERY_LINE_MESSAGES);
  const cut = shown.slice(0, Math.max(0, shown.length - ROOM_DELIVERY_FULL_MESSAGES - ROOM_DELIVERY_LINE_MESSAGES));
  const beforeShown = continuation ? roomContinuationFromSeq(params.toSeq) - 1 : 0;
  const counted = beforeShown > 0
    ? { count: beforeShown, first: 1, last: beforeShown }
    : cut.length > 0 ? { count: cut.length, first: cut[0]!.seq, last: cut[cut.length - 1]!.seq } : null;
  const isNew = (message: AgentRoomMessageV1) => message.seq >= params.fromSeq && !isOwnMessage(member, message);
  const others = room.members.filter((entry) => entry.agentId !== member.agentId).map((entry) => entry.name ?? entry.agentId);

  const parts = [
    `Room «${room.title}» (room ${room.id}). You are ${member.name ?? member.agentId}, here with ${[`${userLabel} (the user)`, ...others].join(', ')}.`,
  ];
  if (continuation) {
    const previous = continuation.previousSessionId ? ` (session ${continuation.previousSessionId}; mis_hilos reads it)` : '';
    parts.push(`This is a new thread of yours in this room: the one before it${previous} answered everything through #${params.fromSeq - 1}. Below is the room so far, your own messages included.`);
  }
  if (counted) {
    parts.push(`${counted.count} earlier messages (#${counted.first}–#${counted.last}) are not shown; read them with sala_leer (roomId ${room.id}, toSeq ${counted.last}).`);
  }
  if (lines.length > 0) {
    parts.push(`Earlier, one line each (full text with sala_leer):\n${lines
      .map((message) => oneLine(roomMessageAuthorLabel(message.author, userLabel), message)).join('\n')}`);
  }
  const quotes = { bySeq: new Map(params.messages.map((message) => [message.seq, message])), readerAgentId: member.agentId, maxChars: ROOM_DELIVERY_LINE_CHARS };
  const answered = full.filter((message) => !isNew(message));
  if (answered.length > 0) parts.push(`Already answered:\n\n${formatRoomMessages({ messages: answered, userLabel, quotes })}`);
  parts.push(`${lines.some(isNew) ? 'Latest, in full' : 'New messages'}:\n\n${formatRoomMessages({ messages: full.filter(isNew), userLabel, quotes })}`);
  parts.push([
    'The final message of your turn is posted to the room as your reply.',
    `To hand the floor to someone, mention them (${others.length > 0 ? `@${others[0]}` : '@Name'}), or everyone with @todos; mention @${userLabel} to ask the user.`,
    'Use sala_leer to read more of the room.',
    'To show the user one of your sessions (when they ask what you are doing, or you speak of work in another thread), put its id alone on a line as <session>ID</session>: the room shows it as a card with its live status. The ids are in your list of other threads and in mis_hilos.',
  ].join(' '));
  return parts.join('\n\n');
}

const ROOM_DELIVERY_LOCAL_ID_PREFIX = 'room.';

/**
 * The localId a delivery is sent with: the room and the member, plus a nonce so every delivery is a
 * new message (a retried send reuses it, so it lands once). Readers look a message up by localId in
 * a route parameter (`/v2/sessions/:id/messages/by-local-id/:localId`), which the relay caps at 100
 * characters, so it uses only URL-safe characters: with UUID ids and an 8-character nonce it is 87.
 */
export function roomDeliveryLocalId(params: Readonly<{ roomId: string; agentId: string; nonce: string }>): string {
  return `${ROOM_DELIVERY_LOCAL_ID_PREFIX}${params.roomId}.${params.agentId}.${params.nonce}`;
}

export function parseRoomDeliveryLocalId(localId: string): Readonly<{ roomId: string; agentId: string }> | null {
  if (!localId.startsWith(ROOM_DELIVERY_LOCAL_ID_PREFIX)) return null;
  const [roomId, agentId, nonce, ...rest] = localId.slice(ROOM_DELIVERY_LOCAL_ID_PREFIX.length).split('.');
  return roomId && agentId && nonce && rest.length === 0 ? { roomId, agentId } : null;
}

const USER_MENTION_ID = '\u0000user';

/** Whom an agent's reply mentions: other members (never itself) and the user. */
export function resolveRoomReply(params: Readonly<{ room: AgentRoomV1; agentId: string; text: string }>): Readonly<{ mentions: string[]; mentionsUser: boolean }> {
  const mentioned = resolveRoomMentions(params.text, [
    ...params.room.members,
    { agentId: USER_MENTION_ID, name: roomUserLabel(params.room) },
  ], { everyone: params.room.members.map((member) => member.agentId) });
  return {
    mentions: mentioned.filter((id) => id !== USER_MENTION_ID && id !== params.agentId),
    mentionsUser: mentioned.includes(USER_MENTION_ID),
  };
}

export type RoomReplyNotice = 'reply' | 'mention' | 'brake';

/**
 * What the user is told about an agent's reply: every reply once, as a messaging app does (it stands
 * for its thread's turn-finished notice, which a room turn doesn't send), as a mention when it
 * mentions them outside the agent's own chat (`kind: 'direct'`). And that it handed the floor on
 * after `AGENT_ROOM_MAX_AGENT_TURNS` agent turns in a row, so the brake holds it.
 */
export function roomReplyNotices(params: Readonly<{ room: AgentRoomV1; message: AgentRoomMessageV1; agentStreak: number }>): RoomReplyNotice[] {
  const notices: RoomReplyNotice[] = [params.room.kind !== 'direct' && params.message.mentionsUser ? 'mention' : 'reply'];
  if (params.message.mentions.length > 0 && params.agentStreak >= AGENT_ROOM_MAX_AGENT_TURNS) notices.push('brake');
  return notices;
}

import { parseSessionPermissionModeAlias, type SessionPermissionMode } from '../sessionMetadata/sessionPermissionModes.js';
import {
  agentRoomUnreadRange,
  formatRoomMessages,
  resolveRoomMentions,
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
 * room; its turn's final text is posted back as its reply, and its marker moves to what it got.
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
  const line = `[#${message.seq}] ${label}: ${message.text.replace(/\s+/g, ' ').trim()}`;
  return line.length <= ROOM_DELIVERY_LINE_CHARS ? line : `${line.slice(0, ROOM_DELIVERY_LINE_CHARS - 1)}…`;
}

/**
 * The message a member's thread gets: who is in the room, what it hadn't read (others' messages
 * from `fromSeq` to `toSeq`, a long backlog cut down) and how its reply reaches the room.
 */
export function buildRoomDeliveryPrompt(params: Readonly<{
  room: AgentRoomV1;
  member: AgentRoomMember;
  messages: readonly AgentRoomMessageV1[];
  fromSeq: number;
  toSeq: number;
}>): string {
  const { room, member } = params;
  const userLabel = roomUserLabel(room);
  const unread = [...new Map(params.messages
    .filter((message) => message.seq >= params.fromSeq && message.seq <= params.toSeq)
    .filter((message) => !(message.author.kind === 'agent' && message.author.agentId === member.agentId))
    .map((message) => [message.seq, message])).values()]
    .sort((a, b) => a.seq - b.seq);
  const full = unread.slice(-ROOM_DELIVERY_FULL_MESSAGES);
  const lines = unread.slice(0, -ROOM_DELIVERY_FULL_MESSAGES).slice(-ROOM_DELIVERY_LINE_MESSAGES);
  const counted = unread.slice(0, Math.max(0, unread.length - ROOM_DELIVERY_FULL_MESSAGES - ROOM_DELIVERY_LINE_MESSAGES));
  const others = room.members.filter((entry) => entry.agentId !== member.agentId).map((entry) => entry.name ?? entry.agentId);

  const parts = [
    `Room «${room.title}» (room ${room.id}). You are ${member.name ?? member.agentId}, here with ${[`${userLabel} (the user)`, ...others].join(', ')}.`,
  ];
  if (counted.length > 0) {
    const first = counted[0]!.seq;
    const last = counted[counted.length - 1]!.seq;
    parts.push(`${counted.length} earlier messages (#${first}–#${last}) are not shown; read them with sala_leer (roomId ${room.id}, toSeq ${last}).`);
  }
  if (lines.length > 0) {
    parts.push(`Earlier, one line each (full text with sala_leer):\n${lines
      .map((message) => oneLine(roomMessageAuthorLabel(message.author, userLabel), message)).join('\n')}`);
  }
  parts.push(`${lines.length > 0 ? 'Latest, in full' : 'New messages'}:\n\n${formatRoomMessages({ messages: full, userLabel })}`);
  parts.push([
    'The final message of your turn is posted to the room as your reply.',
    `To hand the floor to someone, mention them (${others.length > 0 ? `@${others[0]}` : '@Name'}); mention @${userLabel} to ask the user.`,
    'Use sala_leer to read more of the room.',
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
  ]);
  return {
    mentions: mentioned.filter((id) => id !== USER_MENTION_ID && id !== params.agentId),
    mentionsUser: mentioned.includes(USER_MENTION_ID),
  };
}

export type RoomReplyNotice = 'mention' | 'brake';

/**
 * What the user is told about an agent's reply: that it mentions them, and that it handed the floor
 * on after `AGENT_ROOM_MAX_AGENT_TURNS` agent turns in a row, so the brake holds it.
 */
export function roomReplyNotices(params: Readonly<{ message: AgentRoomMessageV1; agentStreak: number }>): RoomReplyNotice[] {
  const notices: RoomReplyNotice[] = [];
  if (params.message.mentionsUser) notices.push('mention');
  if (params.message.mentions.length > 0 && params.agentStreak >= AGENT_ROOM_MAX_AGENT_TURNS) notices.push('brake');
  return notices;
}

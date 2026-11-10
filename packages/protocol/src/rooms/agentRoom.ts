import { z } from 'zod';

import { SESSION_PERMISSION_INTENT_INPUTS } from '../sessionMetadata/sessionPermissionModes.js';

/**
 * A room ("sala"): a group chat of the user and the agents they invite, sealed in the account's
 * UserKVStore under kind `agent_room`. Keys stay opaque (titles and text live in the sealed value),
 * and each kind of row has its own prefix so one listing of rooms is never crowded out by their
 * messages (a listing returns at most 1000 rows and has no cursor):
 *
 * - `room/<roomId>`: the room (title, members, the seq of its last message).
 * - `roommsg/<roomId>/<seq>`: one message each, created with version -1 in the same atomic write
 *   that moves the room's `lastSeq` to it, so concurrent writers get gap-free, ordered seqs. Messages
 *   are read by exact key (the seqs are known), never listed.
 * - `roomseat/<roomId>/<agentId>`: a member's thread in the room and its read marker.
 *
 * Every schema is passthrough: a field this build doesn't know (written by a newer one) is kept
 * when the record is read and rewritten.
 */
export const AGENT_ROOM_KV_PREFIX = 'room/';
export const AGENT_ROOM_MESSAGE_KV_PREFIX = 'roommsg/';
export const AGENT_ROOM_SEAT_KV_PREFIX = 'roomseat/';

/** Seqs are zero-padded to this many digits so a key's order is its message's order. */
const SEQ_DIGITS = 10;
export const AGENT_ROOM_MAX_SEQ = 10 ** SEQ_DIGITS - 1;

export function agentRoomKvKey(roomId: string): string {
  return `${AGENT_ROOM_KV_PREFIX}${roomId}`;
}

export function agentRoomMessageKvKey(roomId: string, seq: number): string {
  if (!Number.isSafeInteger(seq) || seq < 1 || seq > AGENT_ROOM_MAX_SEQ) {
    throw new RangeError(`room message seq must be an integer from 1 to ${AGENT_ROOM_MAX_SEQ}: ${seq}`);
  }
  return `${AGENT_ROOM_MESSAGE_KV_PREFIX}${roomId}/${String(seq).padStart(SEQ_DIGITS, '0')}`;
}

export function agentRoomSeatsKvPrefix(roomId: string): string {
  return `${AGENT_ROOM_SEAT_KV_PREFIX}${roomId}/`;
}

export function agentRoomSeatKvKey(roomId: string, agentId: string): string {
  return `${agentRoomSeatsKvPrefix(roomId)}${agentId}`;
}

/** Which room a UserKVStore key belongs to, and which of its rows it is; null for other keys. */
export function parseAgentRoomKvKey(key: string): Readonly<{ kind: 'room' | 'message' | 'seat'; roomId: string }> | null {
  const [head, roomId, ...rest] = key.split('/');
  if (!roomId) return null;
  const prefix = `${head}/`;
  if (prefix === AGENT_ROOM_KV_PREFIX && rest.length === 0) return { kind: 'room', roomId };
  if (rest.length !== 1 || !rest[0]) return null;
  if (prefix === AGENT_ROOM_MESSAGE_KV_PREFIX) return { kind: 'message', roomId };
  if (prefix === AGENT_ROOM_SEAT_KV_PREFIX) return { kind: 'seat', roomId };
  return null;
}

const SeqSchema = z.number().int().min(1).max(AGENT_ROOM_MAX_SEQ);

/** An invited agent: it works in the room from its own folder on one machine. */
const AgentRoomMemberSchema = z.object({
  agentId: z.string().min(1),
  name: z.string().optional(),
  emoji: z.string().optional(),
  machineId: z.string().min(1),
  directory: z.string().min(1),
  /**
   * Whether another agent's mention starts a turn for it. The app sets it (after the Consumer Terms
   * warning for the providers that need one); absent means only the user's mentions wake it.
   */
  wakeByAgents: z.boolean().optional(),
  /** How its turns in the room run; absent means YOLO, as for tasks. */
  permissionMode: z.enum(SESSION_PERMISSION_INTENT_INPUTS).optional(),
}).passthrough();
export type AgentRoomMember = z.infer<typeof AgentRoomMemberSchema>;

export const AgentRoomV1Schema = z.object({
  v: z.literal(1),
  id: z.string().min(1),
  title: z.string().trim().min(1),
  /** How the members call the user (and mention them: `@<userName>`); "User" when absent. */
  userName: z.string().optional(),
  members: z.array(AgentRoomMemberSchema),
  /** The seq of the room's last message; 0 before the first one. */
  lastSeq: z.number().int().min(0).max(AGENT_ROOM_MAX_SEQ),
  /** Set by the user's pause button: nothing is delivered until it is cleared; running turns finish. */
  pausedAt: z.number().optional(),
  /** Set when the user archived it: nothing is delivered. */
  archivedAt: z.number().optional(),
  createdAt: z.number(),
  updatedAt: z.number(),
}).passthrough();
export type AgentRoomV1 = z.infer<typeof AgentRoomV1Schema>;

const AgentRoomAuthorSchema = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('user') }).passthrough(),
  /** Name and emoji as they were when it wrote, so the log reads on its own. */
  z.object({
    kind: z.literal('agent'),
    agentId: z.string().min(1),
    name: z.string().optional(),
    emoji: z.string().optional(),
    sessionId: z.string().optional(),
  }).passthrough(),
]);
export type AgentRoomAuthor = z.infer<typeof AgentRoomAuthorSchema>;

export const AgentRoomMessageV1Schema = z.object({
  v: z.literal(1),
  roomId: z.string().min(1),
  seq: SeqSchema,
  at: z.number(),
  author: AgentRoomAuthorSchema,
  text: z.string().min(1),
  /** The members it mentions (agent ids), in the order they appear. */
  mentions: z.array(z.string().min(1)),
  /** An agent's message that mentions the user (`@<userName>`). */
  mentionsUser: z.boolean().optional(),
  /** The message this one answers: an option the user picked on it (it mentions only its author). */
  replyTo: z.object({ seq: SeqSchema }).passthrough().optional(),
}).passthrough();
export type AgentRoomMessageV1 = z.infer<typeof AgentRoomMessageV1Schema>;

export const AgentRoomSeatV1Schema = z.object({
  v: z.literal(1),
  roomId: z.string().min(1),
  agentId: z.string().min(1),
  /** The member's thread in the room, once it has one. */
  sessionId: z.string().optional(),
  /** Every message up to this seq is read; 0 before the first. */
  readThroughSeq: z.number().int().min(0).max(AGENT_ROOM_MAX_SEQ),
  /**
   * The delivery its thread is working: sent with `localId` (once `sent`), reading through
   * `throughSeq`. Cleared, with the marker moved to `throughSeq`, when that turn ends.
   */
  inFlight: z.object({
    localId: z.string().min(1),
    throughSeq: z.number().int().min(0).max(AGENT_ROOM_MAX_SEQ),
    at: z.number(),
    sent: z.boolean().optional(),
  }).passthrough().optional(),
  updatedAt: z.number(),
}).passthrough();
export type AgentRoomSeatV1 = z.infer<typeof AgentRoomSeatV1Schema>;

export function parseAgentRoomV1(value: unknown): AgentRoomV1 | null {
  const parsed = AgentRoomV1Schema.safeParse(value);
  return parsed.success ? parsed.data : null;
}

export function parseAgentRoomMessageV1(value: unknown): AgentRoomMessageV1 | null {
  const parsed = AgentRoomMessageV1Schema.safeParse(value);
  return parsed.success ? parsed.data : null;
}

export function parseAgentRoomSeatV1(value: unknown): AgentRoomSeatV1 | null {
  const parsed = AgentRoomSeatV1Schema.safeParse(value);
  return parsed.success ? parsed.data : null;
}

export type AgentRoomMessageDraft = Readonly<{
  author: AgentRoomAuthor;
  text: string;
  mentions?: readonly string[];
  mentionsUser?: boolean;
  replyTo?: Readonly<{ seq: number }>;
}>;

/**
 * The room after one more message, and that message: it takes the room's next seq. Both are written
 * together (the room with its version, the message with version -1), so a concurrent writer that
 * took the same seq makes this write fail and re-run on the newer room.
 */
export function appendRoomMessage(
  room: AgentRoomV1,
  draft: AgentRoomMessageDraft,
  now: number,
): Readonly<{ room: AgentRoomV1; message: AgentRoomMessageV1 }> {
  const text = draft.text.trim();
  if (!text) throw new RangeError('a room message needs text');
  const seq = room.lastSeq + 1;
  agentRoomMessageKvKey(room.id, seq);
  return {
    room: { ...room, lastSeq: seq, updatedAt: now },
    message: {
      v: 1,
      roomId: room.id,
      seq,
      at: now,
      author: draft.author,
      text,
      mentions: [...new Set(draft.mentions ?? [])],
      ...(draft.mentionsUser ? { mentionsUser: true } : {}),
      ...(draft.replyTo ? { replyTo: { seq: draft.replyTo.seq } } : {}),
    },
  };
}

/** Case- and accent-insensitive text, compared code unit by code unit. */
function fold(value: string): string {
  return value.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase();
}

const WORD_CHAR = /[\p{L}\p{N}_]/u;

/** `@todos` / `@all`: every agent of the room (folded, as names are compared). */
const EVERYONE_MENTIONS = ['todos', 'all'];

/**
 * The members `text` mentions with `@` and their whole name (any case or accents), in the order
 * they first appear. `@todos` or `@all` mentions `everyone` (by default every member given) at that
 * point. An `@` inside a word (an email) or followed by a longer word mentions no one.
 */
export function resolveRoomMentions(
  text: string,
  members: ReadonlyArray<Readonly<{ agentId: string; name?: string }>>,
  options: Readonly<{ everyone?: readonly string[] }> = {},
): string[] {
  const everyone = options.everyone ?? members.map((member) => member.agentId);
  const candidates = members
    .flatMap((member) => (member.name?.trim() ? [{ agentId: member.agentId, name: fold(member.name.trim()) }] : []))
    .sort((a, b) => b.name.length - a.name.length);
  const folded = fold(text);
  const mentioned: string[] = [];
  for (let at = folded.indexOf('@'); at !== -1; at = folded.indexOf('@', at + 1)) {
    if (at > 0 && WORD_CHAR.test(folded[at - 1]!)) continue;
    const start = at + 1;
    const match = candidates.find((candidate) => folded.startsWith(candidate.name, start)
      && !WORD_CHAR.test(folded[start + candidate.name.length] ?? ''));
    if (match) {
      if (!mentioned.includes(match.agentId)) mentioned.push(match.agentId);
      continue;
    }
    if (EVERYONE_MENTIONS.some((word) => folded.startsWith(word, start) && !WORD_CHAR.test(folded[start + word.length] ?? ''))) {
      for (const agentId of everyone) if (!mentioned.includes(agentId)) mentioned.push(agentId);
    }
  }
  return mentioned;
}

/** The seqs a member hasn't read yet (inclusive); null when it is caught up. */
export function agentRoomUnreadRange(
  room: AgentRoomV1,
  seat: AgentRoomSeatV1 | null,
): Readonly<{ fromSeq: number; toSeq: number }> | null {
  const fromSeq = (seat?.readThroughSeq ?? 0) + 1;
  return fromSeq <= room.lastSeq ? { fromSeq, toSeq: room.lastSeq } : null;
}

/** How the room's members call the user. */
export function roomUserLabel(room: AgentRoomV1): string {
  return room.userName?.trim() || 'User';
}

/** Who wrote a message: the user's label, or the agent's name and emoji. */
export function roomMessageAuthorLabel(author: AgentRoomAuthor, userLabel: string): string {
  if (author.kind === 'user') return userLabel;
  const name = author.name?.trim() || author.agentId;
  return author.emoji ? `${name} ${author.emoji}` : name;
}

/** The messages as one text, oldest first, each with its seq and who said it. */
export function formatRoomMessages(params: Readonly<{ messages: readonly AgentRoomMessageV1[]; userLabel: string }>): string {
  const bySeq = new Map(params.messages.map((message) => [message.seq, message]));
  return [...bySeq.values()]
    .sort((a, b) => a.seq - b.seq)
    .map((message) => `[#${message.seq}] ${roomMessageAuthorLabel(message.author, params.userLabel)}${message.replyTo ? ` (answer to #${message.replyTo.seq})` : ''}: ${message.text}`)
    .join('\n\n');
}

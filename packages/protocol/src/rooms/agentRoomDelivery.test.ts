import { describe, expect, it } from 'vitest';

import type { AgentRoomMessageV1, AgentRoomSeatV1, AgentRoomV1 } from './agentRoom.js';
import {
  AGENT_ROOM_MAX_AGENT_TURNS,
  buildRoomDeliveryPrompt,
  decideRoomDelivery,
  parseRoomDeliveryLocalId,
  resolveRoomReply,
  roomAgentStreak,
  roomDeliveryLocalId,
  roomMemberPermissionMode,
  roomReplyNotices,
} from './agentRoomDelivery.js';

const mateo = { agentId: 'a-mateo', name: 'Mateo', emoji: '🤖', machineId: 'm1', directory: '/work/movil', wakeByAgents: true };
const tomas = { agentId: 'a-tomas', name: 'Tomás', machineId: 'm2', directory: '/work/escritorio' };

function room(overrides: Partial<AgentRoomV1> = {}): AgentRoomV1 {
  return { v: 1, id: 'r1', title: 'App nueva', userName: 'Manny', members: [mateo, tomas], lastSeq: 0, createdAt: 0, updatedAt: 0, ...overrides };
}

const user = { kind: 'user' as const };
const agent = (member: typeof mateo | typeof tomas) => ({ kind: 'agent' as const, agentId: member.agentId, name: member.name });

function log(...entries: Array<[AgentRoomMessageV1['author'], string, string[]?]>): AgentRoomMessageV1[] {
  return entries.map(([author, text, mentions], index) => ({ v: 1, roomId: 'r1', seq: index + 1, at: index, author, text, mentions: mentions ?? [] }));
}

function seat(overrides: Partial<AgentRoomSeatV1> = {}): AgentRoomSeatV1 {
  return { v: 1, roomId: 'r1', agentId: 'a-mateo', readThroughSeq: 0, updatedAt: 0, ...overrides };
}

describe('decideRoomDelivery', () => {
  it('delivers everything unread when the user mentions the member', () => {
    const messages = log([user, 'Hola a todos'], [agent(tomas), 'Hola'], [user, '@Mateo ¿cómo vas?', ['a-mateo']]);
    expect(decideRoomDelivery({ room: room({ lastSeq: 3 }), member: mateo, seat: null, messages }))
      .toEqual({ kind: 'deliver', fromSeq: 1, toSeq: 3 });
  });

  it('waits for a member that is mentioned while its turn runs, and for a paused room', () => {
    const messages = log([user, '@Mateo ¿y?', ['a-mateo']]);
    const busy = seat({ inFlight: { localId: 'room:r1:a-mateo:0:x', throughSeq: 0, at: 0 } });
    expect(decideRoomDelivery({ room: room({ lastSeq: 1 }), member: mateo, seat: busy, messages })).toEqual({ kind: 'wait', reason: 'busy' });
    expect(decideRoomDelivery({ room: room({ lastSeq: 1, pausedAt: 5 }), member: mateo, seat: null, messages })).toEqual({ kind: 'wait', reason: 'paused' });
  });

  it('does not wake a member for messages that do not mention it, or that it wrote', () => {
    const messages = log([user, 'Hola'], [agent(mateo), 'Yo, @Mateo', ['a-mateo']]);
    expect(decideRoomDelivery({ room: room({ lastSeq: 2 }), member: mateo, seat: null, messages })).toEqual({ kind: 'wait', reason: 'not_mentioned' });
    expect(decideRoomDelivery({ room: room({ lastSeq: 2 }), member: mateo, seat: seat({ readThroughSeq: 2 }), messages }))
      .toEqual({ kind: 'wait', reason: 'caught_up' });
  });

  it('lets an agent hand the floor only to a member that may be woken by agents', () => {
    const handOff = log([user, '@Tomás empieza', ['a-tomas']], [agent(tomas), 'Listo, @Mateo sigue', ['a-mateo']]);
    expect(decideRoomDelivery({ room: room({ lastSeq: 2 }), member: mateo, seat: null, messages: handOff }))
      .toEqual({ kind: 'deliver', fromSeq: 1, toSeq: 2 });

    const toTomas = log([user, '@Mateo empieza', ['a-mateo']], [agent(mateo), 'Listo, @Tomás sigue', ['a-tomas']]);
    const tomasSeat = { ...seat(), agentId: 'a-tomas', readThroughSeq: 1 };
    expect(decideRoomDelivery({ room: room({ lastSeq: 2 }), member: tomas, seat: tomasSeat, messages: toTomas }))
      .toEqual({ kind: 'wait', reason: 'needs_user' });
    // "Que conteste": the user's own mention wakes it, with everything it hadn't read.
    const answered = [...toTomas, ...log([user, '@Tomás contesta', ['a-tomas']]).map((message) => ({ ...message, seq: 3 }))];
    expect(decideRoomDelivery({ room: room({ lastSeq: 3 }), member: tomas, seat: tomasSeat, messages: answered }))
      .toEqual({ kind: 'deliver', fromSeq: 2, toSeq: 3 });
  });

  it(`stops after ${AGENT_ROOM_MAX_AGENT_TURNS} agent turns in a row without the user`, () => {
    const bounce = (count: number) => log(
      [user, '@Mateo @Tomás platiquen', ['a-mateo', 'a-tomas']],
      ...Array.from({ length: count }, (_, index): [AgentRoomMessageV1['author'], string, string[]] => (index % 2
        ? [agent(mateo), '@Tomás', ['a-tomas']]
        : [agent(tomas), '@Mateo', ['a-mateo']])),
    );
    const five = bounce(5);
    expect(decideRoomDelivery({ room: room({ lastSeq: 6 }), member: mateo, seat: seat({ readThroughSeq: 4 }), messages: five }))
      .toEqual({ kind: 'deliver', fromSeq: 5, toSeq: 6 });
    const six = bounce(6).map((message) => (message.seq === 7 ? { ...message, author: agent(tomas), mentions: ['a-mateo'] } : message));
    expect(decideRoomDelivery({ room: room({ lastSeq: 7 }), member: mateo, seat: seat({ readThroughSeq: 6 }), messages: six }))
      .toEqual({ kind: 'wait', reason: 'brake' });
  });
});

describe('roomAgentStreak', () => {
  it('counts the agent messages in a row up to a seq, back to the user\'s last one', () => {
    const messages = log([agent(tomas), 'a'], [user, 'b'], [agent(tomas), 'c'], [agent(mateo), 'd']);
    expect(roomAgentStreak(messages, 4)).toBe(2);
    expect(roomAgentStreak(messages, 2)).toBe(0);
  });
});

describe('buildRoomDeliveryPrompt', () => {
  it('gives a short backlog in full, without the member\'s own messages, and says how the reply works', () => {
    const messages = log([user, '@Mateo ¿cómo vas?', ['a-mateo']], [agent(mateo), 'Bien'], [agent(tomas), 'Yo también, @Mateo', ['a-mateo']]);
    const prompt = buildRoomDeliveryPrompt({ room: room({ lastSeq: 3 }), member: mateo, messages, fromSeq: 1, toSeq: 3 });
    expect(prompt).toContain('room r1');
    expect(prompt).toContain('[#1] Manny: @Mateo ¿cómo vas?\n\n[#3] Tomás: Yo también, @Mateo');
    expect(prompt).not.toContain('[#2]');
    expect(prompt).toContain('posted to the room as your reply');
    expect(prompt).toContain('sala_leer');
  });

  it('cuts a long backlog: the last 15 in full, one line each for the 50 before, the rest only counted', () => {
    const long = 'x'.repeat(400);
    const messages = log(...Array.from({ length: 70 }, (_, index): [AgentRoomMessageV1['author'], string] => [user, `m${index + 1} ${long}\nsegunda línea`]));
    const prompt = buildRoomDeliveryPrompt({ room: room({ lastSeq: 70 }), member: mateo, messages, fromSeq: 1, toSeq: 70 });
    expect(prompt).toContain('5 earlier messages (#1–#5)');
    expect(prompt).toContain('toSeq 5');
    const lines = prompt.split('\n');
    const abbreviated = lines.filter((line) => /^\[#(\d+)\] /.test(line) && Number(line.match(/^\[#(\d+)\]/)![1]) <= 55);
    expect(abbreviated.map((line) => Number(line.match(/^\[#(\d+)\]/)![1]))).toEqual(Array.from({ length: 50 }, (_, index) => index + 6));
    expect(abbreviated.every((line) => line.length <= 160 && line.endsWith('…'))).toBe(true);
    expect(prompt).toContain(`[#56] Manny: m56 ${long}\nsegunda línea`);
    expect(prompt).toContain(`[#70] Manny: m70 ${long}\nsegunda línea`);
    expect(prompt).not.toContain('[#1] ');
  });
});

describe('room delivery local ids', () => {
  it('carry the room and the member', () => {
    const localId = roomDeliveryLocalId({ roomId: 'r1', agentId: 'a-mateo', nonce: 'n1' });
    expect(parseRoomDeliveryLocalId(localId)).toEqual({ roomId: 'r1', agentId: 'a-mateo' });
    expect(parseRoomDeliveryLocalId('spawn-first:abc')).toBeNull();
  });

  it('fit the relay\'s 100-character route parameter once URL-encoded (transcript lookup by localId)', () => {
    const localId = roomDeliveryLocalId({ roomId: crypto.randomUUID(), agentId: crypto.randomUUID(), nonce: 'a1b2c3d4' });
    expect(encodeURIComponent(localId).length).toBeLessThanOrEqual(100);
  });
});

describe('resolveRoomReply', () => {
  it('finds the members and the user it mentions, never the author itself', () => {
    expect(resolveRoomReply({ room: room(), agentId: 'a-mateo', text: '@Mateo terminé; @Tomás revisa y @manny decide' }))
      .toEqual({ mentions: ['a-tomas'], mentionsUser: true });
    expect(resolveRoomReply({ room: room(), agentId: 'a-mateo', text: 'Listo.' })).toEqual({ mentions: [], mentionsUser: false });
    // An agent's @todos is every other agent; it doesn't mention the user.
    expect(resolveRoomReply({ room: room(), agentId: 'a-mateo', text: '@todos terminé' })).toEqual({ mentions: ['a-tomas'], mentionsUser: false });
  });
});

describe('roomReplyNotices', () => {
  const reply = (mentions: string[], mentionsUser = false): AgentRoomMessageV1 => ({
    v: 1, roomId: 'r1', seq: 9, at: 0, author: agent(mateo), text: 'x', mentions, ...(mentionsUser ? { mentionsUser } : {}),
  });

  it('tells the user when an agent mentions them, and when a hand-off hits the brake', () => {
    expect(roomReplyNotices({ message: reply([], true), agentStreak: 1 })).toEqual(['mention']);
    expect(roomReplyNotices({ message: reply(['a-tomas']), agentStreak: AGENT_ROOM_MAX_AGENT_TURNS })).toEqual(['brake']);
    expect(roomReplyNotices({ message: reply(['a-tomas']), agentStreak: AGENT_ROOM_MAX_AGENT_TURNS - 1 })).toEqual([]);
    expect(roomReplyNotices({ message: reply([]), agentStreak: AGENT_ROOM_MAX_AGENT_TURNS })).toEqual([]);
  });
});

describe('roomMemberPermissionMode', () => {
  it('is YOLO unless the member says otherwise', () => {
    expect(roomMemberPermissionMode(mateo)).toBe('yolo');
    expect(roomMemberPermissionMode({ ...mateo, permissionMode: 'default' })).toBe('default');
  });
});

import { describe, expect, it } from 'vitest';

import { decodeBase64 } from '../crypto/base64.js';
import { openAccountScopedBlobCiphertext, sealAccountScopedBlobCiphertext } from '../crypto/accountScopedCipher.js';
import {
  agentRoomKvKey,
  agentRoomMessageKvKey,
  agentRoomSeatKvKey,
  agentRoomUnreadRange,
  appendRoomMessage,
  formatRoomMessages,
  parseAgentRoomMessageV1,
  parseAgentRoomSeatV1,
  parseAgentRoomV1,
  resolveRoomMentions,
  type AgentRoomMessageV1,
  type AgentRoomV1,
} from './agentRoom.js';

function room(overrides: Partial<AgentRoomV1> = {}): AgentRoomV1 {
  return {
    v: 1,
    id: 'r1',
    title: 'App nueva',
    members: [
      { agentId: 'a-mateo', name: 'Mateo', emoji: '🤖', machineId: 'm1', directory: '/work/app-movil' },
      { agentId: 'a-tomas', name: 'Tomás', machineId: 'm2', directory: '/work/app-escritorio' },
    ],
    lastSeq: 0,
    createdAt: 0,
    updatedAt: 0,
    ...overrides,
  };
}

function message(seq: number, author: AgentRoomMessageV1['author'], text: string): AgentRoomMessageV1 {
  return { v: 1, roomId: 'r1', seq, at: seq * 1_000, author, text, mentions: [] };
}

describe('agent room keys', () => {
  it('keeps keys opaque and lists a room\'s messages in seq order', () => {
    expect(agentRoomKvKey('r1')).toBe('room/r1');
    expect(agentRoomSeatKvKey('r1', 'a-mateo')).toBe('roomseat/r1/a-mateo');
    const keys = [10, 9, 100].map((seq) => agentRoomMessageKvKey('r1', seq));
    expect([...keys].sort()).toEqual([agentRoomMessageKvKey('r1', 9), agentRoomMessageKvKey('r1', 10), agentRoomMessageKvKey('r1', 100)]);
    expect(agentRoomMessageKvKey('r1', 9)).toBe('roommsg/r1/0000000009');
  });

  it('refuses a seq its key cannot order', () => {
    expect(() => agentRoomMessageKvKey('r1', 0)).toThrow();
    expect(() => agentRoomMessageKvKey('r1', 10_000_000_000)).toThrow();
  });
});

describe('agent room records', () => {
  it('keep fields a newer build added', () => {
    expect(parseAgentRoomV1({ ...room(), futureField: { keep: true } })).toMatchObject({ futureField: { keep: true } });
    expect(parseAgentRoomMessageV1({ ...message(1, { kind: 'user' }, 'Hola'), reactions: ['👍'] })).toMatchObject({ reactions: ['👍'] });
    expect(parseAgentRoomSeatV1({ v: 1, roomId: 'r1', agentId: 'a-mateo', readThroughSeq: 3, updatedAt: 0, futureField: 1 }))
      .toMatchObject({ readThroughSeq: 3, futureField: 1 });
  });

  it('reject records that are not well formed', () => {
    expect(parseAgentRoomV1({ ...room(), lastSeq: -1 })).toBeNull();
    expect(parseAgentRoomMessageV1({ ...message(1, { kind: 'user' }, 'Hola'), seq: 0 })).toBeNull();
    expect(parseAgentRoomSeatV1({ v: 1, roomId: 'r1', agentId: 'a-mateo', updatedAt: 0 })).toBeNull();
  });

  it('are sealed under their own account-scoped kind', () => {
    const material = { type: 'dataKey', machineKey: new Uint8Array(32).fill(9) } as const;
    const ciphertext = sealAccountScopedBlobCiphertext({ kind: 'agent_room', material, payload: room(), randomBytes: (n) => new Uint8Array(n) });
    expect(decodeBase64(ciphertext, 'base64')[1]).toBe(16);
    expect(openAccountScopedBlobCiphertext({ kind: 'agent_room', material, ciphertext })?.value).toEqual(room());
    expect(openAccountScopedBlobCiphertext({ kind: 'agent_task', material, ciphertext })).toBeNull();
  });
});

describe('appendRoomMessage', () => {
  it('gives the message the room\'s next seq and advances the room to it', () => {
    const { room: next, message: appended } = appendRoomMessage(
      room({ lastSeq: 4 }),
      { author: { kind: 'agent', agentId: 'a-mateo', name: 'Mateo', sessionId: 's1' }, text: '  Listo, @Tomás revisa  ', mentions: ['a-tomas', 'a-tomas'] },
      7_000,
    );
    expect(next).toMatchObject({ lastSeq: 5, updatedAt: 7_000 });
    expect(appended).toEqual({
      v: 1, roomId: 'r1', seq: 5, at: 7_000,
      author: { kind: 'agent', agentId: 'a-mateo', name: 'Mateo', sessionId: 's1' },
      text: 'Listo, @Tomás revisa', mentions: ['a-tomas'],
    });
  });

  it('refuses a message without text', () => {
    expect(() => appendRoomMessage(room(), { author: { kind: 'user' }, text: '   ' }, 1)).toThrow();
  });
});

describe('resolveRoomMentions', () => {
  const members = [
    { agentId: 'a-mateo', name: 'Mateo' },
    { agentId: 'a-tomas', name: 'Tomás' },
    { agentId: 'a-leo', name: 'Leo' },
    { agentId: 'a-leonardo', name: 'Leonardo' },
    { agentId: 'a-nomada', name: 'Claude Nómada' },
    { agentId: 'a-unnamed' },
  ];

  it('finds the members mentioned with @, in order and once each', () => {
    expect(resolveRoomMentions('@tomas mira esto y luego @Mateo; gracias @TOMÁS', members)).toEqual(['a-tomas', 'a-mateo']);
  });

  it('matches the whole name, the longest first', () => {
    expect(resolveRoomMentions('@Leonardo y @claude nómada', members)).toEqual(['a-leonardo', 'a-nomada']);
    expect(resolveRoomMentions('@Leo, ¿y tú?', members)).toEqual(['a-leo']);
  });

  it('ignores an @ inside a word or a longer name', () => {
    expect(resolveRoomMentions('escríbele a manny@mateo.dev o a @Mateo2', members)).toEqual([]);
  });
});

describe('agentRoomUnreadRange', () => {
  it('is what came after the seat\'s marker, up to the room\'s last message', () => {
    expect(agentRoomUnreadRange(room({ lastSeq: 7 }), { v: 1, roomId: 'r1', agentId: 'a-mateo', readThroughSeq: 3, updatedAt: 0 }))
      .toEqual({ fromSeq: 4, toSeq: 7 });
    expect(agentRoomUnreadRange(room({ lastSeq: 2 }), null)).toEqual({ fromSeq: 1, toSeq: 2 });
    expect(agentRoomUnreadRange(room({ lastSeq: 7 }), { v: 1, roomId: 'r1', agentId: 'a-mateo', readThroughSeq: 7, updatedAt: 0 }))
      .toBeNull();
  });
});

describe('formatRoomMessages', () => {
  it('says who said what, in seq order', () => {
    const text = formatRoomMessages({
      userLabel: 'Manny',
      messages: [
        message(3, { kind: 'agent', agentId: 'a-tomas', name: 'Tomás' }, 'Va.'),
        message(1, { kind: 'user' }, '@Mateo ¿cómo vamos?'),
        message(2, { kind: 'agent', agentId: 'a-mateo', name: 'Mateo', emoji: '🤖' }, 'Casi.\nFalta el login. @Tomás'),
        message(3, { kind: 'agent', agentId: 'a-tomas', name: 'Tomás' }, 'Va.'),
      ],
    });
    expect(text).toBe('[#1] Manny: @Mateo ¿cómo vamos?\n\n[#2] Mateo 🤖: Casi.\nFalta el login. @Tomás\n\n[#3] Tomás: Va.');
  });
});

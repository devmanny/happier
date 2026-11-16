import { describe, expect, it, vi } from 'vitest';

import { readTurnReplyAfterLocalId, readTurnReplyFromRows } from './readTurnReplyAfterLocalId';

/** The relay's session and transcript routes (HTTP boundary): what the test's relay holds. */
const relay = vi.hoisted(() => ({
  session: null as Record<string, unknown> | null,
  sent: null as { seq: number } | null,
  rows: [] as unknown[],
}));

vi.mock('@/session/transport/http/sessionsHttp', async (importOriginal) => ({
  ...await importOriginal<typeof import('@/session/transport/http/sessionsHttp')>(),
  fetchSessionById: async () => relay.session,
  fetchSessionsPage: async () => ({ sessions: [], nextCursor: null, hasNext: false }),
}));
vi.mock('@/api/session/transcriptMessageLookup', async (importOriginal) => ({
  ...await importOriginal<typeof import('@/api/session/transcriptMessageLookup')>(),
  findTranscriptEncryptedMessageByLocalId: async () => relay.sent,
}));
vi.mock('@/api/session/fetchEncryptedTranscriptWindow', async (importOriginal) => ({
  ...await importOriginal<typeof import('@/api/session/fetchEncryptedTranscriptWindow')>(),
  fetchEncryptedTranscriptPageAfterSeq: async () => relay.rows,
}));

const ctx = { encryptionKey: new Uint8Array([1]), encryptionVariant: 'legacy' as const };
let seq = 10;
const row = (v: unknown) => ({ seq: ++seq, createdAt: seq, content: { t: 'plain' as const, v } });
const assistant = (text: string) => row({ role: 'assistant', content: { type: 'text', text }, meta: {} });
const user = (text: string) => row({ role: 'user', content: { type: 'text', text }, meta: {} });
const completed = () => row({ role: 'agent', content: { type: 'acp', data: { type: 'task_complete', id: 'turn-1' } } });
const failed = () => row({ role: 'agent', content: { type: 'acp', data: { type: 'turn_failed', id: 'turn-1' } } });

describe('readTurnReplyFromRows', () => {
  it('is the turn\'s final assistant message, finished once the turn completes', () => {
    expect(readTurnReplyFromRows({ rows: [assistant('Reviso…'), assistant('Listo: @Tomás revisa'), completed()], ctx }))
      .toEqual({ finished: true, text: 'Listo: @Tomás revisa' });
    expect(readTurnReplyFromRows({ rows: [assistant('Reviso…')], ctx })).toEqual({ finished: false, text: 'Reviso…' });
    expect(readTurnReplyFromRows({ rows: [failed()], ctx })).toEqual({ finished: true, text: null });
  });

  it('ends at the next user message: what comes after belongs to another turn', () => {
    expect(readTurnReplyFromRows({ rows: [assistant('Primero'), completed(), user('otra cosa'), assistant('Otra respuesta')], ctx }))
      .toEqual({ finished: true, text: 'Primero' });
  });
});

describe('readTurnReplyAfterLocalId', () => {
  const machineKey = new Uint8Array(32).fill(4);
  const read = () => readTurnReplyAfterLocalId({
    credentials: { token: 't', encryption: { type: 'dataKey', publicKey: machineKey, machineKey } },
    sessionId: 's-old-thread-1',
    localId: 'room.r1.a-mateo.n1',
  });
  const thread = (archivedAt: number | null) => ({ id: 's-old-thread-1', encryptionMode: 'plain', archivedAt });

  it('says the thread is gone when its session doesn\'t exist any more, or is archived before the turn finished', async () => {
    relay.session = null;
    expect(await read()).toBe('thread_gone');

    relay.session = thread(5);
    relay.sent = { seq: 10 };
    relay.rows = [assistant('Reviso…')];
    expect(await read()).toBe('thread_gone');
    // The delivery never reached its transcript: it never will.
    relay.sent = null;
    expect(await read()).toBe('thread_gone');
  });

  it('still reads the reply of a turn that finished before its thread was archived, and waits on a live thread', async () => {
    relay.session = thread(5);
    relay.sent = { seq: 10 };
    relay.rows = [assistant('Listo'), completed()];
    expect(await read()).toEqual({ finished: true, text: 'Listo' });

    relay.session = thread(null);
    relay.rows = [assistant('Reviso…')];
    expect(await read()).toEqual({ finished: false, text: 'Reviso…' });
    relay.sent = null;
    expect(await read()).toBeNull();
  });
});

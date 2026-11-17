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
// Rows as real Codex app-server and ACP (Kimi) threads commit them, their content stripped.
const agent = (content: unknown) => row({ role: 'agent', content, meta: { sentFrom: 'cli', source: 'cli' } });
const message = (provider: string, text: string) => agent({ type: 'acp', provider, data: { type: 'message', message: text } });
const codexWork = () => [
  agent({ type: 'codex', data: { type: 'tool-call', callId: 'call-1', id: 'item-1', name: 'exec', input: {} } }),
  agent({ type: 'codex', data: { type: 'tool-call-result', callId: 'call-1', id: 'item-2', output: {} } }),
  agent({ type: 'codex', data: { type: 'token_count', id: 'usage-1', key: 'codex-app-server:thread-1', tokens: { total: 1 } } }),
];
const codexTurnEnd = (turnId: string) => agent({ type: 'acp', provider: 'codex', data: { type: 'task_complete', id: turnId } });
const ready = () => row({ role: 'agent', content: { id: 'ready-1', type: 'event', data: { type: 'ready' } } });

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

  // Every agent message is an `acp` `message`, the ones written mid-turn too. A turn ends at its
  // `task_complete` (ACP, and Codex app-server turns since they commit one) or the session's `ready`.
  it('is not ended by what the agent writes mid-turn, only by the turn\'s end', () => {
    const codexMidTurn = [message('codex', 'Voy a revisar la agenda.'), ...codexWork()];
    expect(readTurnReplyFromRows({ rows: codexMidTurn, ctx })).toEqual({ finished: false, text: 'Voy a revisar la agenda.' });
    expect(readTurnReplyFromRows({ rows: [...codexMidTurn, message('codex', 'Listo: la agenda está al día.'), ...codexWork(), ready()], ctx }))
      .toEqual({ finished: true, text: 'Listo: la agenda está al día.' });
    // A message steered into the running turn: the turn goes on past it, so what came before it isn't a reply.
    expect(readTurnReplyFromRows({
      rows: [message('codex', 'Voy a revisar la agenda.'), ...codexWork(), user('y también el correo'), message('codex', 'Listo.'), ready()],
      ctx,
    })).toEqual({ finished: false, text: 'Voy a revisar la agenda.' });

    const acpMidTurn = [agent({ type: 'acp', provider: 'kimi', data: { type: 'thinking', text: '…' } }), message('kimi', 'Voy a eliminarlo.')];
    expect(readTurnReplyFromRows({ rows: acpMidTurn, ctx })).toEqual({ finished: false, text: 'Voy a eliminarlo.' });
    expect(readTurnReplyFromRows({
      rows: [...acpMidTurn, message('kimi', 'Listo, ya no existe.'), agent({ type: 'acp', provider: 'kimi', data: { type: 'task_complete', id: 'session-turn:1' } }), ready()],
      ctx,
    })).toEqual({ finished: true, text: 'Listo, ya no existe.' });
  });

  // A message queued while a Codex app-server turn ran is drained as the next turn, with no `ready`
  // between the two (the session never went idle): the first turn's end is its `task_complete`.
  it('ends a Codex turn at its own end when the queued message after it ran as the next turn', () => {
    expect(readTurnReplyFromRows({
      rows: [
        message('codex', 'Voy a revisar la agenda.'), ...codexWork(), message('codex', 'Listo: la agenda está al día.'), codexTurnEnd('turn-1'),
        user('y también el correo'), message('codex', 'El correo también.'), ...codexWork(), codexTurnEnd('turn-2'), ready(),
      ],
      ctx,
    })).toEqual({ finished: true, text: 'Listo: la agenda está al día.' });
  });

  // Codex starts a goal continuation itself, right after the turn it continues: the rows that
  // follow that turn's end have no user message before them, and are another turn's.
  it('is the reply of the turn up to its end, not of a turn the agent started itself after it', () => {
    // Rows are read in `seq` order: the successor's are built after the turn's.
    const successor = () => [message('codex', 'Sigo con la meta: reviso el registro.'), ...codexWork()];
    expect(readTurnReplyFromRows({
      rows: [message('codex', 'Reviso.'), ...codexWork(), message('codex', 'Listo turno 1.'), codexTurnEnd('turn-1'), ...successor()],
      ctx,
    })).toEqual({ finished: true, text: 'Listo turno 1.' });
    expect(readTurnReplyFromRows({ rows: [message('codex', 'Listo.'), ready(), ...successor()], ctx }))
      .toEqual({ finished: true, text: 'Listo.' });
    expect(readTurnReplyFromRows({ rows: [message('codex', 'Voy.'), failed(), ...successor()], ctx }))
      .toEqual({ finished: true, text: 'Voy.' });
  });

  // Claude's `task_complete` comes from its Stop hook, best-effort, while its final output comes from
  // the transcript scanner: the output can be committed after the marker. It is still that turn's.
  it('keeps a Claude turn\'s final output committed after its own end marker', () => {
    const claudeOutput = (text: string, stopReason: string) => agent({
      type: 'output',
      data: { type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text }], stop_reason: stopReason } },
    });
    expect(readTurnReplyFromRows({
      rows: [claudeOutput('Reviso el correo.', 'tool_use'), completed(), claudeOutput('Listo: el correo está al día.', 'end_turn')],
      ctx,
    })).toEqual({ finished: true, text: 'Listo: el correo está al día.' });
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

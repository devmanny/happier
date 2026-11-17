import { fetchEncryptedTranscriptPageAfterSeq, type TranscriptRow } from '@/api/session/fetchEncryptedTranscriptWindow';
import { findTranscriptEncryptedMessageByLocalId } from '@/api/session/transcriptMessageLookup';
import type { Credentials } from '@/persistence';
import { isMemoryArtifactDecryptedRow, isSessionUserMessage } from '@/session/query/detectSessionTurnInFlight';
import { isSessionTurnEnd, isSessionTurnEndMarker } from '@/session/shared/sessionTurnLifecycle';
import type { SessionEncryptionContext } from '@/session/transport/encryption/sessionEncryptionContext';

import { extractRecentMessagesFromTranscriptRows } from './getSessionRecentMessages';
import { resolveSessionTransportContext } from './resolveSessionTransportContext';
import { decryptTranscriptRowContent, readAssistantTurnFailure } from './sendSessionMessage';

export type TurnReply = Readonly<{
  /** The turn ended or failed: its end (`isSessionTurnEnd`) or a failure marker is in the transcript. */
  finished: boolean;
  /** Its final assistant message, if it wrote one. */
  text: string | null;
}>;

/**
 * The reply of the turn a user message started, from the transcript rows that follow it (oldest
 * first): its last assistant message up to the next user message or the turn's end marker
 * (`isSessionTurnEndMarker`, past which only the turn's own terminal output still counts), and
 * whether the turn ended. A message the agent writes mid-turn doesn't
 * end it, and neither does a user message steered into it.
 */
export function readTurnReplyFromRows(params: Readonly<{
  rows: readonly Pick<TranscriptRow, 'seq' | 'content' | 'createdAt'>[];
  ctx: SessionEncryptionContext;
}>): TurnReply {
  const turnRows: Array<Pick<TranscriptRow, 'seq' | 'content' | 'createdAt'>> = [];
  let finished = false;
  let pastEndMarker = false;
  for (const row of [...params.rows].sort((a, b) => a.seq - b.seq)) {
    const decrypted = decryptTranscriptRowContent({ content: row.content, ctx: params.ctx });
    if (isSessionUserMessage(decrypted)) break;
    const turnRow = !isMemoryArtifactDecryptedRow(decrypted);
    const turnEnd = turnRow && isSessionTurnEnd(decrypted);
    const endMarker = turnRow && isSessionTurnEndMarker(decrypted);
    // What follows the turn's end marker is another turn's, even with no user message before it (a
    // Codex goal continuation), except the turn's own terminal output: Claude's Stop-hook marker can
    // be committed before the final output its transcript scanner commits.
    if (pastEndMarker && !(turnEnd && !endMarker)) continue;
    if (turnEnd || readAssistantTurnFailure(decrypted)) finished = true;
    turnRows.push(row);
    if (endMarker) pastEndMarker = true;
  }
  const replies = extractRecentMessagesFromTranscriptRows({
    rows: turnRows,
    ctx: params.ctx,
    includeUser: false,
    includeAssistant: true,
    maxCharsPerMessage: null,
  });
  return { finished, text: replies.at(-1)?.text ?? null };
}

/** One page of the transcript route, the same size the other transcript readers use. */
const TRANSCRIPT_PAGE_ROWS = 100;

/**
 * The reply of the turn the message sent with `localId` started, read from the session's
 * transcript; null when that message isn't in the transcript (yet). `'thread_gone'` when the turn
 * can never finish there: the session doesn't exist any more, or it is archived and the turn hadn't
 * finished (a turn that finished before the archive still gives its reply).
 */
export async function readTurnReplyAfterLocalId(params: Readonly<{
  credentials: Credentials;
  sessionId: string;
  localId: string;
}>): Promise<TurnReply | 'thread_gone' | null> {
  const target = await resolveSessionTransportContext({ credentials: params.credentials, idOrPrefix: params.sessionId });
  if (!target.ok) {
    if (target.code === 'session_not_found') return 'thread_gone';
    throw new Error(`session ${params.sessionId} is not readable (${target.code})`);
  }
  const archived = target.rawSession.archivedAt !== null && target.rawSession.archivedAt !== undefined;
  const token = params.credentials.token;
  const sent = await findTranscriptEncryptedMessageByLocalId({ token, sessionId: target.sessionId, localId: params.localId });
  if (!sent) return archived ? 'thread_gone' : null;
  const rows: TranscriptRow[] = [];
  for (let afterSeq = sent.seq; ;) {
    const page = await fetchEncryptedTranscriptPageAfterSeq({ token, sessionId: target.sessionId, afterSeq, limit: TRANSCRIPT_PAGE_ROWS });
    rows.push(...page);
    if (page.length < TRANSCRIPT_PAGE_ROWS) break;
    afterSeq = Math.max(...page.map((row) => row.seq));
  }
  const reply = readTurnReplyFromRows({ rows, ctx: target.ctx });
  return archived && !reply.finished ? 'thread_gone' : reply;
}

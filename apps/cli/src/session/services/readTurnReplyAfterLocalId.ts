import { fetchEncryptedTranscriptPageAfterSeq, type TranscriptRow } from '@/api/session/fetchEncryptedTranscriptWindow';
import { findTranscriptEncryptedMessageByLocalId } from '@/api/session/transcriptMessageLookup';
import type { Credentials } from '@/persistence';
import { isSessionUserMessage } from '@/session/query/detectSessionTurnInFlight';
import type { SessionEncryptionContext } from '@/session/transport/encryption/sessionEncryptionContext';

import { extractRecentMessagesFromTranscriptRows } from './getSessionRecentMessages';
import { resolveSessionTransportContext } from './resolveSessionTransportContext';
import { decryptTranscriptRowContent, isAssistantTurnCompletionProof, readAssistantTurnFailure } from './sendSessionMessage';

export type TurnReply = Readonly<{
  /** The turn completed or failed (a completion or failure marker is in the transcript). */
  finished: boolean;
  /** Its final assistant message, if it wrote one. */
  text: string | null;
}>;

/**
 * The reply of the turn a user message started, from the transcript rows that follow it (oldest
 * first): its last assistant message up to the next user message, and whether the turn ended.
 */
export function readTurnReplyFromRows(params: Readonly<{
  rows: readonly Pick<TranscriptRow, 'seq' | 'content' | 'createdAt'>[];
  ctx: SessionEncryptionContext;
}>): TurnReply {
  const turnRows: Array<Pick<TranscriptRow, 'seq' | 'content' | 'createdAt'>> = [];
  let finished = false;
  for (const row of [...params.rows].sort((a, b) => a.seq - b.seq)) {
    const decrypted = decryptTranscriptRowContent({ content: row.content, ctx: params.ctx });
    if (isSessionUserMessage(decrypted)) break;
    if (isAssistantTurnCompletionProof(decrypted) || readAssistantTurnFailure(decrypted)) finished = true;
    turnRows.push(row);
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
 * transcript; null when that message isn't in the transcript (yet).
 */
export async function readTurnReplyAfterLocalId(params: Readonly<{
  credentials: Credentials;
  sessionId: string;
  localId: string;
}>): Promise<TurnReply | null> {
  const target = await resolveSessionTransportContext({ credentials: params.credentials, idOrPrefix: params.sessionId });
  if (!target.ok) throw new Error(`session ${params.sessionId} is not readable (${target.code})`);
  const token = params.credentials.token;
  const sent = await findTranscriptEncryptedMessageByLocalId({ token, sessionId: target.sessionId, localId: params.localId });
  if (!sent) return null;
  const rows: TranscriptRow[] = [];
  for (let afterSeq = sent.seq; ;) {
    const page = await fetchEncryptedTranscriptPageAfterSeq({ token, sessionId: target.sessionId, afterSeq, limit: TRANSCRIPT_PAGE_ROWS });
    rows.push(...page);
    if (page.length < TRANSCRIPT_PAGE_ROWS) break;
    afterSeq = Math.max(...page.map((row) => row.seq));
  }
  return readTurnReplyFromRows({ rows, ctx: target.ctx });
}

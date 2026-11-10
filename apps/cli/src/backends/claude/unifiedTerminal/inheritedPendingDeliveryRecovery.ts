import { stat } from 'node:fs/promises';

import { isHappierProviderOnlyPromptSuffix } from '@/agent/runtime/prompt/resolveProviderPromptForDispatch';
import { readJsonlFileBackwardPage } from '@/api/directSessions/filePaging/jsonlBackwardPager';
import type { InheritedUncertainPendingDelivery, SessionClientPort } from '@/api/session/sessionClientPort';
import type { UserMessage } from '@/api/types';
import { logger } from '@/ui/logger';

import { resolveClaudeStructuredUserMessageRouting } from '../utils/structuredMessages/resolveClaudeStructuredUserMessageRouting';
import { readClaudeUnifiedTranscriptPromptEvidence } from './acceptedPromptTranscriptDiscovery';
import { normalizeClaudeUnifiedPromptIdentityText } from './promptIdentity';

/**
 * Startup recovery for deliveries a replaced runner left `delivery_outcome_uncertain`.
 *
 * The server marks every `delivering` row uncertain when a new runner registers, because only the
 * provider can know whether it received the prompt. For Claude that evidence is the transcript the
 * predecessor wrote: exactly one consumption of the exact prompt settles the row as accepted; no
 * consumption at all, once the predecessor's terminal host is confirmed dead, sends it again once.
 * Anything that could be another prompt, or a predecessor that may still act, stays with the owner.
 */

export type ClaudeInheritedPendingDeliveryVerdict = 'received' | 'not_received' | 'undetermined';

export type ClaudeInheritedPendingDeliveryDecision = Readonly<{
  localId: string;
  verdict: ClaudeInheritedPendingDeliveryVerdict;
  outcome: 'settled' | 'resent' | 'left' | 'failed';
}>;

type InheritedDeliveryRecoveryClient = Pick<
  SessionClientPort,
  'listInheritedUncertainPendingDeliveries' | 'settleInheritedPendingDeliveryAccepted' | 'resendInheritedPendingDeliveryAsNew'
>;

export function classifyClaudeInheritedPendingDelivery(params: Readonly<{
  /** The prompt this runtime would have queued for the row. */
  promptText: string;
  createdAtMs: number;
  /** Rows from this point on belong to the replacement provider, not the predecessor. */
  evidenceBeforeMs: number;
  /** The predecessor's transcript, or null when it cannot be read. */
  transcriptRows: readonly unknown[] | null;
  predecessorConfirmedDead: boolean;
  /** Prompts of the other inherited rows: an identical one makes the evidence anonymous. */
  competingPromptTexts: readonly string[];
}>): ClaudeInheritedPendingDeliveryVerdict {
  const target = normalizeClaudeUnifiedPromptIdentityText(params.promptText);
  if (!target || params.transcriptRows === null) return 'undetermined';
  if (params.competingPromptTexts.some((text) => normalizeClaudeUnifiedPromptIdentityText(text) === target)) {
    return 'undetermined';
  }

  let consumed = 0;
  let releasedFromNativeQueue = false;
  // Absence only means something in a transcript that already existed when the row was created.
  let coversRowCreation = false;
  // Evidence that may be this prompt without identifying it (batched, wrapped, or undated).
  let related = false;
  for (const row of params.transcriptRows) {
    const rowAtMs = readRowTimestampMs(row);
    if (rowAtMs !== null && rowAtMs <= params.createdAtMs) coversRowCreation = true;
    const evidence = readClaudeUnifiedTranscriptPromptEvidence(row);
    if (!evidence) continue;
    const atMs = evidence.timestampMs;
    if (atMs !== null && (atMs < params.createdAtMs || atMs >= params.evidenceBeforeMs)) continue;
    const texts = (evidence.kind === 'consumed' ? evidence.texts : [evidence.text]).map(normalizeClaudeUnifiedPromptIdentityText);
    // The provider prompt is the stored text, plus any context Happier appends for the provider only.
    const exact = texts.some((text) => text === target || (
      text.startsWith(`${target}\n\n`) && isHappierProviderOnlyPromptSuffix(text.slice(target.length + 2))
    ));
    if (!exact) {
      if (texts.some((text) => text.includes(target))) related = true;
      continue;
    }
    if (atMs === null) {
      related = true;
    } else if (evidence.kind === 'consumed') {
      consumed += 1;
    } else if (evidence.operation === 'remove') {
      // Claude only holds a queued prompt in memory; releasing one is explained by its consumption row.
      releasedFromNativeQueue = true;
    }
  }

  if (consumed === 1 && !related) return 'received';
  if (consumed > 0 || related || releasedFromNativeQueue || !params.predecessorConfirmedDead || !coversRowCreation) {
    return 'undetermined';
  }
  return 'not_received';
}

/** The text runClaude queues for a user message (`structuredRouting?.queuedText ?? content.text`). */
function readQueuedPromptText(message: UserMessage | null): string | null {
  const text = message?.content?.text;
  if (typeof text !== 'string') return null;
  return resolveClaudeStructuredUserMessageRouting({ text, meta: message?.meta })?.queuedText ?? text;
}

function readRowTimestampMs(row: unknown): number | null {
  const raw = row && typeof row === 'object' ? (row as Record<string, unknown>).timestamp : null;
  if (typeof raw !== 'string') return null;
  const parsed = Date.parse(raw);
  return Number.isFinite(parsed) ? parsed : null;
}

const TRANSCRIPT_PAGE_BYTES = 1_000_000;
// Claude stamps adjacent rows out of order by a few hundred milliseconds (observed); keep reading
// one minute past the window start so a row at the page boundary is never skipped.
const WINDOW_START_MARGIN_MS = 60_000;

/**
 * Reads the transcript backwards only as far as the evidence window reaches: these files reach
 * hundreds of megabytes. Null when the file is missing, empty, or cannot be read completely.
 */
async function readTranscriptRowsSince(transcriptPath: string, sinceMs: number): Promise<unknown[] | null> {
  try {
    if ((await stat(transcriptPath)).size === 0) return null;
    const rows: unknown[] = [];
    let endOffsetBytes: number | null = null;
    for (;;) {
      const page = await readJsonlFileBackwardPage({
        filePath: transcriptPath,
        endOffsetBytes,
        maxBytes: TRANSCRIPT_PAGE_BYTES,
        maxItems: Infinity,
      });
      let reachedBeforeWindow = false;
      for (const item of page.items) {
        rows.push(item.value);
        const atMs = readRowTimestampMs(item.value);
        if (atMs !== null && atMs < sinceMs - WINDOW_START_MARGIN_MS) reachedBeforeWindow = true;
      }
      if (reachedBeforeWindow || page.reachedStart) return rows;
      if (endOffsetBytes !== null && page.nextEndOffsetBytes >= endOffsetBytes) return null;
      endOffsetBytes = page.nextEndOffsetBytes;
    }
  } catch {
    return null;
  }
}

export async function recoverClaudeUnifiedInheritedPendingDeliveries(params: Readonly<{
  client: InheritedDeliveryRecoveryClient;
  transcriptPath: string | null;
  predecessorConfirmedDead: boolean;
  evidenceBeforeMs: number;
}>): Promise<readonly ClaudeInheritedPendingDeliveryDecision[]> {
  const inherited: readonly InheritedUncertainPendingDelivery[] = await params.client.listInheritedUncertainPendingDeliveries?.() ?? [];
  if (inherited.length === 0) return [];

  const sinceMs = Math.min(...inherited.map((row) => row.createdAt ?? Number.POSITIVE_INFINITY));
  const transcriptRows = params.transcriptPath && Number.isFinite(sinceMs)
    ? await readTranscriptRowsSince(params.transcriptPath, sinceMs)
    : null;
  const promptTexts = inherited.map((row) => readQueuedPromptText(row.message));
  const resolved = new Set<string>();
  const decisions: ClaudeInheritedPendingDeliveryDecision[] = [];

  for (const [index, row] of inherited.entries()) {
    const promptText = promptTexts[index] ?? null;
    const verdict: ClaudeInheritedPendingDeliveryVerdict = promptText === null || row.createdAt === null
      ? 'undetermined'
      : classifyClaudeInheritedPendingDelivery({
        promptText,
        createdAtMs: row.createdAt,
        evidenceBeforeMs: params.evidenceBeforeMs,
        transcriptRows,
        predecessorConfirmedDead: params.predecessorConfirmedDead,
        competingPromptTexts: promptTexts.filter((text, other): text is string => other !== index && text !== null),
      });

    let outcome: ClaudeInheritedPendingDeliveryDecision['outcome'] = 'left';
    try {
      if (verdict === 'received') {
        // The server settles an ordinary row only after every queued row ahead of it.
        const ordinary = (row.requestedAction?.kind ?? 'enqueue') === 'enqueue';
        const heldBehind = ordinary && row.earlierQueuedLocalIds.some((localId) => !resolved.has(localId));
        if (!heldBehind) {
          outcome = await params.client.settleInheritedPendingDeliveryAccepted?.(row.localId) === true ? 'settled' : 'failed';
        }
      } else if (verdict === 'not_received') {
        outcome = await params.client.resendInheritedPendingDeliveryAsNew?.(row.localId) === true ? 'resent' : 'failed';
      }
    } catch (error) {
      outcome = 'failed';
      logger.infoFile('[unified]: inherited uncertain delivery resolution failed', {
        localId: row.localId,
        verdict,
        error: error instanceof Error ? error.message : String(error),
      });
    }
    if (outcome === 'settled' || outcome === 'resent') resolved.add(row.localId);
    logger.infoFile('[unified]: inherited uncertain delivery recovery', {
      localId: row.localId,
      verdict,
      outcome,
      predecessorConfirmedDead: params.predecessorConfirmedDead,
      transcriptRead: transcriptRows !== null,
    });
    decisions.push({ localId: row.localId, verdict, outcome });
  }
  return decisions;
}

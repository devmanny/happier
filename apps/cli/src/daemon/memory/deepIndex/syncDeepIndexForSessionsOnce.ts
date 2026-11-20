import type { DecryptedTranscriptRow } from '@/session/replay/decryptTranscriptRows';
import type { MemoryContentPolicyV1, MemoryCoveragePolicyV1 } from '@happier-dev/protocol';
import { configuration } from '@/configuration';
import { logger } from '@/ui/logger';

import type { SummaryShardIndexDbHandle } from '../summaryShardIndexDb';
import type { DeepIndexDbHandle, DeepIndexMessage } from './deepIndexDb';
import type { OperationalMemoryEmbeddingsSettings } from '../resolveOperationalMemoryEmbeddingsSettings';
import {
  extractMemoryIndexableTranscriptItemFromDecryptedRow,
} from '../semanticTranscript/extractMemoryIndexableTranscriptItem';

/** One server page after the cursor: `lastSeq` is the page's last row, decryptable or not. */
export type DeepIndexTranscriptPage = Readonly<{
  rows: DecryptedTranscriptRow[];
  hasMore: boolean;
  lastSeq: number | null;
}>;

export type SyncDeepIndexSettings = Readonly<{
  enabled: boolean;
  indexMode: 'deep';
  coveragePolicy?: MemoryCoveragePolicyV1;
  contentPolicy?: MemoryContentPolicyV1;
  deep: Readonly<{
    includeAssistantAcpMessage: boolean;
    failureBackoffBaseMs: number;
    failureBackoffMaxMs: number;
  }>;
  embeddings?: OperationalMemoryEmbeddingsSettings | null;
}>;

function shouldSkipAssistantAcpPayloadRow(params: Readonly<{
  row: DecryptedTranscriptRow;
  includeAssistantAcpMessage: boolean;
}>): boolean {
  if (params.includeAssistantAcpMessage) return false;
  if (params.row.role !== 'agent') return false;
  const content =
    params.row.content && typeof params.row.content === 'object' && !Array.isArray(params.row.content)
      ? params.row.content as Record<string, unknown>
      : null;
  if (!content) return false;
  const contentType = content.type;
  if (contentType !== 'acp' && contentType !== 'codex') return false;
  const data =
    content.data && typeof content.data === 'object' && !Array.isArray(content.data)
      ? content.data as Record<string, unknown>
      : null;
  return data?.type === 'message' || data?.type === 'reasoning';
}

function extractIndexableMessages(params: Readonly<{
  sessionId: string;
  rows: readonly DecryptedTranscriptRow[];
  settings: SyncDeepIndexSettings;
}>): DeepIndexMessage[] {
  const messages: DeepIndexMessage[] = [];
  params.rows.forEach((row, index) => {
    if (shouldSkipAssistantAcpPayloadRow({ row, includeAssistantAcpMessage: params.settings.deep.includeAssistantAcpMessage })) return;
    const item = extractMemoryIndexableTranscriptItemFromDecryptedRow({
      sessionId: params.sessionId,
      row,
      index,
      contentPolicy: params.settings.contentPolicy,
    });
    if (!item) return;
    messages.push({ seq: item.seq, createdAtMs: item.createdAtMs, role: item.role, kind: item.kind, text: item.text });
  });
  return messages;
}

async function embedMissingMessages(params: Readonly<{
  sessionId: string;
  deep: DeepIndexDbHandle;
  settings: SyncDeepIndexSettings;
  nowMs: number;
  limit: number;
  embedDocuments?: (texts: readonly string[]) => Promise<Float32Array[]>;
}>): Promise<void> {
  const emb = params.settings.embeddings;
  const provider = String(emb?.providerKind ?? '').trim();
  const modelId = String(emb?.modelId ?? '').trim();
  if (emb?.enabled !== true || typeof params.embedDocuments !== 'function' || !provider || !modelId) return;

  const pending = params.deep.listMessagesWithoutEmbeddings({ sessionId: params.sessionId, provider, modelId, limit: params.limit });
  if (pending.length === 0) return;
  try {
    const vectors = await params.embedDocuments(pending.map((message) => message.text));
    if (!Array.isArray(vectors) || vectors.length !== pending.length) return;
    pending.forEach((message, index) => {
      const embedding = vectors[index];
      if (!(embedding instanceof Float32Array) || embedding.length === 0) return;
      params.deep.upsertEmbedding({ sessionId: message.sessionId, seq: message.seq, provider, modelId, embedding, updatedAtMs: params.nowMs });
    });
  } catch (error) {
    logger.debug('[memoryWorker] Missing message embeddings backfill failed (best-effort)', {
      sessionId: params.sessionId,
      provider,
      modelId,
      messageCount: pending.length,
      message: error instanceof Error ? error.message : String(error),
    });
  }
}

/**
 * Reads ONE transcript page per session after its deep cursor (`tier1` owns the per-session
 * cursor and failure backoff) and writes every admitted message to the deep index, so a long
 * history is read over many passes and a restart resumes where the cursor stopped.
 */
export async function syncDeepIndexForSessionsOnce(params: Readonly<{
  sessionIds: readonly string[];
  /** The latest seq the session list reported per session (the session's head). */
  observedSeqBySessionId?: ReadonlyMap<string, number>;
  tier1: SummaryShardIndexDbHandle;
  deep: DeepIndexDbHandle;
  settings: SyncDeepIndexSettings;
  now: () => number;
  fetchDecryptedTranscriptPageAfterSeq: (args: Readonly<{ sessionId: string; afterSeq: number; limit: number }>) => Promise<DeepIndexTranscriptPage>;
  embedDocuments?: (texts: readonly string[]) => Promise<Float32Array[]>;
}>): Promise<void> {
  if (!params.settings.enabled) return;
  if (params.settings.indexMode !== 'deep') return;
  const nowMs = Math.max(0, Math.trunc(params.now()));
  const pageLimit = Math.max(1, Math.min(500, Math.trunc(configuration.memoryMaxTranscriptWindowMessages)));
  const run = {
    sessionsConsidered: 0,
    sessionsProcessed: 0,
    sessionsIndexed: 0,
    sessionsFailed: 0,
    rawRowsFetched: 0,
    semanticRowsFound: 0,
    deepChunksCreated: 0,
  };
  const markFailure = (sessionId: string) => {
    params.tier1.markDeepIndexFailure({
      sessionId,
      nowMs,
      backoffBaseMs: params.settings.deep.failureBackoffBaseMs,
      backoffMaxMs: params.settings.deep.failureBackoffMaxMs,
    });
    run.sessionsFailed += 1;
  };

  for (const rawSessionId of params.sessionIds) {
    const sessionId = String(rawSessionId ?? '').trim();
    if (!sessionId) continue;
    run.sessionsConsidered += 1;

    const cursors = params.tier1.getSessionCursors({ sessionId, nowMs });
    if (cursors.nextDeepEligibleAtMs > nowMs) continue;

    const afterSeq = Math.max(0, Math.trunc(cursors.lastDeepIndexedSeq));
    const observedSeq = params.observedSeqBySessionId?.get(sessionId);
    let page: DeepIndexTranscriptPage;
    try {
      page = await params.fetchDecryptedTranscriptPageAfterSeq({ sessionId, afterSeq, limit: pageLimit });
    } catch {
      markFailure(sessionId);
      continue;
    }
    const rows = page.rows;
    run.rawRowsFetched += rows.length;
    if (rows.length > 0) run.sessionsProcessed += 1;
    const pageEndSeq = rows.reduce((max, row) => Math.max(max, row.seq), Math.max(afterSeq, page.lastSeq ?? 0));
    // The rest of the session up to its observed head is rows this index never reads (events,
    // sidechains): without moving to the head, the session would look unread forever.
    const lastScannedSeq = !page.hasMore && typeof observedSeq === 'number' ? Math.max(pageEndSeq, observedSeq) : pageEndSeq;

    try {
      const messages = extractIndexableMessages({ sessionId, rows, settings: params.settings });
      run.semanticRowsFound += messages.length;
      params.deep.upsertMessages({ sessionId, messages });
      run.deepChunksCreated += messages.length;

      await embedMissingMessages({
        sessionId,
        deep: params.deep,
        settings: params.settings,
        nowMs,
        limit: Math.max(messages.length, pageLimit),
        ...(params.embedDocuments ? { embedDocuments: params.embedDocuments } : {}),
      });

      if (lastScannedSeq > afterSeq) {
        params.tier1.markDeepIndexSuccess({ sessionId, seqTo: lastScannedSeq, nowMs });
      }
      if (messages.length > 0) {
        run.sessionsIndexed += 1;
        params.tier1.recordMemorySessionIndexState({
          sessionId,
          coveragePolicyJson: JSON.stringify(params.settings.coveragePolicy ?? { type: 'full' }),
          status: 'indexed',
          lastSuccessAtMs: nowMs,
          lastAttemptAtMs: nowMs,
          lastCompletedAtMs: nowMs,
          lastObservedSeq: lastScannedSeq,
          lastScannedSeq,
          lastSemanticSeq: messages[messages.length - 1]!.seq,
          lastDeepIndexedSeq: lastScannedSeq,
          rawRowsFetched: rows.length,
          semanticRowsFound: messages.length,
          semanticRowsIndexedDeep: messages.length,
          deepChunkCount: messages.length,
          updatedAtMs: nowMs,
        });
      }
    } catch {
      markFailure(sessionId);
    }
  }

  params.tier1.recordMemoryWorkerRun({
    runId: `deep-${nowMs}`,
    startedAtMs: nowMs,
    finishedAtMs: nowMs,
    trigger: 'sync_deep',
    indexMode: 'deep',
    sessionsConsidered: run.sessionsConsidered,
    sessionsProcessed: run.sessionsProcessed,
    sessionsIndexed: run.sessionsIndexed,
    sessionsFailed: run.sessionsFailed,
    rawRowsFetched: run.rawRowsFetched,
    semanticRowsFound: run.semanticRowsFound,
    deepChunksCreated: run.deepChunksCreated,
  });
}

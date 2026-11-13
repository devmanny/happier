import type {
  MemorySearchCoverageV2,
  MemorySearchQueryV1,
  MemorySearchQueryV2,
  MemorySearchResultV1,
  MemorySearchResultV2,
} from '@happier-dev/protocol';

import type { OperationalMemoryEmbeddingsSettings } from './resolveOperationalMemoryEmbeddingsSettings';
import { openSummaryShardIndexDb } from './summaryShardIndexDb';
import { deepIndexMessageKey, type DeepIndexDbHandle } from './deepIndex/deepIndexDb';
import { rerankHitsWithEmbeddings } from './deepIndex/embeddings/rerankHitsWithEmbeddings';

function trimToMaxChars(text: string, maxChars: number): string {
  const max = Number.isFinite(maxChars) ? Math.max(0, Math.trunc(maxChars)) : 0;
  const value = String(text ?? '');
  if (max <= 0) return '';
  if (value.length <= max) return value;
  return value.slice(0, max);
}

export function searchTier1Memory(params: Readonly<{
  dbPath: string;
  query: MemorySearchQueryV1;
}>): MemorySearchResultV1 {
  const maxResults = params.query.maxResults ?? 20;
  const minScore = params.query.minScore ?? 0;

  const db = openSummaryShardIndexDb({ dbPath: params.dbPath });
  try {
    const hits = db.search({
      query: params.query.query,
      scope: params.query.scope,
      maxResults,
    });
    return {
      v: 1,
      ok: true,
      hits: hits
        .map((hit) => ({
          sessionId: hit.sessionId,
          seqFrom: hit.seqFrom,
          seqTo: hit.seqTo,
          createdAtFromMs: hit.createdAtFromMs,
          createdAtToMs: hit.createdAtToMs,
          summary: hit.summary,
          score: hit.score,
        }))
        .filter((hit) => hit.score >= minScore),
    };
  } catch (e: any) {
    return {
      v: 1,
      ok: false,
      errorCode: 'memory_failed',
      error: e instanceof Error ? e.message : 'Memory search failed',
    };
  } finally {
    db.close();
  }
}

export async function searchTier2Memory(params: Readonly<{
  deep: DeepIndexDbHandle;
  query: MemorySearchQueryV1;
  previewChars: number;
  candidateLimit?: number;
  embeddings?: OperationalMemoryEmbeddingsSettings | null;
  embedQuery?: (queryText: string) => Promise<Float32Array>;
}>): Promise<MemorySearchResultV1> {
  const maxResults = params.query.maxResults ?? 20;
  const minScore = params.query.minScore ?? 0;
  const embeddings = params.embeddings;
  const candidateLimitRaw = params.candidateLimit ?? maxResults;
  const candidateLimit = Math.max(maxResults, Math.max(1, Math.min(1000, Math.floor(candidateLimitRaw))));

  try {
    const candidates = params.deep.searchMessages({
      query: params.query.query,
      scope: params.query.scope,
      limit: candidateLimit,
      offset: 0,
    }).hits;
    // v1 scores are 0..1: BM25 relevance relative to the best candidate.
    const bestScore = candidates.reduce((max, hit) => Math.max(max, hit.score), 0);

    let ranked = candidates.map((hit) => ({
      key: deepIndexMessageKey(hit),
      hit,
      baseScore: bestScore > 0 ? hit.score / bestScore : 0,
      finalScore: undefined as number | undefined,
    }));

    if (embeddings?.enabled === true && typeof params.embedQuery === 'function' && ranked.length > 0) {
      const provider = String(embeddings.providerKind ?? '').trim();
      const modelId = String(embeddings.modelId ?? '').trim();
      if (provider && modelId) {
        try {
          const queryEmbedding = await params.embedQuery(params.query.query);
          const embeddingMap = params.deep.loadEmbeddings({
            provider,
            modelId,
            keys: ranked.map(({ hit }) => ({ sessionId: hit.sessionId, seq: hit.seq })),
          });

          const reranked = rerankHitsWithEmbeddings({
            hits: ranked.map((entry) => ({
              id: entry.key,
              baseScore: entry.baseScore,
              embedding: embeddingMap.get(entry.key) ?? null,
            })),
            queryEmbedding,
            weights: {
              wFts: embeddings.blend.ftsWeight,
              wEmb: embeddings.blend.embeddingWeight,
            },
          });

          const scoreByKey = new Map<string, number>();
          for (const row of reranked) scoreByKey.set(row.id, row.finalScore);
          ranked = ranked
            .map((entry) => ({ ...entry, finalScore: scoreByKey.get(entry.key) ?? entry.baseScore }))
            .sort((a, b) => (b.finalScore ?? 0) - (a.finalScore ?? 0));
        } catch {
          // Best-effort: fall back to base rank ordering.
        }
      }
    }

    return {
      v: 1,
      ok: true,
      hits: ranked
        .slice(0, maxResults)
        .map(({ hit, baseScore, finalScore }) => ({
          sessionId: hit.sessionId,
          seqFrom: hit.seq,
          seqTo: hit.seq,
          createdAtFromMs: hit.createdAtMs,
          createdAtToMs: hit.createdAtMs,
          summary: trimToMaxChars(hit.text, params.previewChars) || hit.text,
          score: Math.max(0, Math.min(1, finalScore ?? baseScore)),
        }))
        .filter((hit) => hit.score >= minScore),
    };
  } catch (e: unknown) {
    return {
      v: 1,
      ok: false,
      errorCode: 'memory_failed',
      error: e instanceof Error ? e.message : 'Memory search failed',
    };
  }
}

const MESSAGE_SEARCH_CURSOR = /^o:(\d{1,9})$/;

/** Full-text message search (`v: 2`): one page of messages, BM25-ranked or newest first, with an offset cursor. */
export function searchDeepIndexMessages(params: Readonly<{
  deep: DeepIndexDbHandle;
  query: MemorySearchQueryV2;
  coverage: MemorySearchCoverageV2;
}>): MemorySearchResultV2 {
  const cursor = params.query.cursor ?? null;
  const cursorMatch = cursor === null ? null : MESSAGE_SEARCH_CURSOR.exec(cursor);
  if (cursor !== null && !cursorMatch) {
    return { v: 2, ok: false, errorCode: 'memory_invalid_query', error: 'memory_invalid_query' };
  }
  const offset = cursorMatch ? Number(cursorMatch[1]) : 0;

  try {
    const page = params.deep.searchMessages({
      query: params.query.query,
      scope: params.query.scope,
      limit: params.query.limit,
      offset,
      order: params.query.order,
    });
    return {
      v: 2,
      ok: true,
      hits: page.hits.map((hit) => ({
        sessionId: hit.sessionId,
        seq: hit.seq,
        createdAtMs: hit.createdAtMs,
        role: hit.role,
        snippet: hit.snippet,
        score: hit.score,
        session: hit.session,
      })),
      nextCursor: page.hasMore ? `o:${offset + page.hits.length}` : null,
      coverage: params.coverage,
    };
  } catch (e: unknown) {
    return { v: 2, ok: false, errorCode: 'memory_failed', error: e instanceof Error ? e.message : 'memory_failed' };
  }
}

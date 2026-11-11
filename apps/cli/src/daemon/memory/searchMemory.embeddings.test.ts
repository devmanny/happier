import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { mkdtemp, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

import { openDeepIndexDb, type DeepIndexDbHandle } from './deepIndex/deepIndexDb';
import type { OperationalMemoryEmbeddingsSettings } from './resolveOperationalMemoryEmbeddingsSettings';
import { searchTier2Memory } from './searchMemory';

const EMBEDDINGS = {
  enabled: true,
  mode: 'custom',
  presetId: null,
  providerKind: 'test',
  modelId: 'm1',
  blend: { ftsWeight: 0.1, embeddingWeight: 0.9 },
  providerConfig: null,
} as unknown as OperationalMemoryEmbeddingsSettings;

const QUERY = { v: 1, query: 'openclaw', scope: { type: 'global' }, mode: 'deep', maxResults: 2 } as const;

describe('searchTier2Memory (embeddings rerank)', () => {
  let dir: string;
  let deep: DeepIndexDbHandle;

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), 'happier-memory-search-emb-'));
    deep = openDeepIndexDb({ dbPath: join(dir, 'deep.sqlite'), accountId: 'acct-1' });
    deep.upsertMessages({
      sessionId: 's1',
      messages: [
        { seq: 1, createdAtMs: 10, role: 'assistant', kind: 'assistant_message', text: 'Older message mentions openclaw.' },
        { seq: 3, createdAtMs: 20, role: 'assistant', kind: 'assistant_message', text: 'Newer message also mentions openclaw.' },
      ],
    });
  });

  afterEach(async () => {
    deep.close();
    await rm(dir, { recursive: true, force: true });
  });

  it('reranks deep hits when embeddings are available and enabled', async () => {
    deep.upsertEmbedding({ sessionId: 's1', seq: 1, provider: 'test', modelId: 'm1', embedding: new Float32Array([1, 0]), updatedAtMs: 1 });
    deep.upsertEmbedding({ sessionId: 's1', seq: 3, provider: 'test', modelId: 'm1', embedding: new Float32Array([0, 1]), updatedAtMs: 1 });

    const towardsOlder = await searchTier2Memory({ deep, query: QUERY, previewChars: 200, candidateLimit: 10, embeddings: EMBEDDINGS, embedQuery: async () => new Float32Array([1, 0]) });
    const towardsNewer = await searchTier2Memory({ deep, query: QUERY, previewChars: 200, candidateLimit: 10, embeddings: EMBEDDINGS, embedQuery: async () => new Float32Array([0, 1]) });

    expect(towardsOlder.ok && towardsOlder.hits[0]?.seqFrom).toBe(1);
    expect(towardsNewer.ok && towardsNewer.hits[0]?.seqFrom).toBe(3);
  });

  it('falls back to text-only ranking when query embedding generation fails', async () => {
    const baseline = await searchTier2Memory({ deep, query: QUERY, previewChars: 200, candidateLimit: 10 });
    const result = await searchTier2Memory({
      deep,
      query: QUERY,
      previewChars: 200,
      candidateLimit: 10,
      embeddings: EMBEDDINGS,
      embedQuery: async () => {
        throw new Error('remote embeddings unavailable');
      },
    });

    expect(baseline.ok && result.ok).toBe(true);
    if (!baseline.ok || !result.ok) return;
    expect(result.hits).toHaveLength(2);
    expect(result.hits.map((hit) => hit.seqFrom)).toEqual(baseline.hits.map((hit) => hit.seqFrom));
  });
});

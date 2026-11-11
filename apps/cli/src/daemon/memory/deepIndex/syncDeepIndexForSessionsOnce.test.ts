import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';

import type { DecryptedTranscriptRow } from '@/session/replay/decryptTranscriptRows';

import { openSummaryShardIndexDb, type SummaryShardIndexDbHandle } from '../summaryShardIndexDb';
import { openDeepIndexDb, type DeepIndexDbHandle } from './deepIndexDb';
import {
  syncDeepIndexForSessionsOnce,
  type DeepIndexTranscriptPage,
  type SyncDeepIndexSettings,
} from './syncDeepIndexForSessionsOnce';

const BASE_SETTINGS: SyncDeepIndexSettings = {
  enabled: true,
  indexMode: 'deep',
  deep: {
    includeAssistantAcpMessage: true,
    failureBackoffBaseMs: 0,
    failureBackoffMaxMs: 0,
  },
};

const TEST_EMBEDDINGS = {
  enabled: true,
  mode: 'custom',
  presetId: null,
  providerKind: 'test',
  modelId: 'm1',
  blend: { ftsWeight: 0.7, embeddingWeight: 0.3 },
  providerConfig: null,
} as unknown as NonNullable<SyncDeepIndexSettings['embeddings']>;

function pageFrom(rows: readonly DecryptedTranscriptRow[], pageSize?: number) {
  return async ({ afterSeq, limit }: Readonly<{ afterSeq: number; limit: number }>): Promise<DeepIndexTranscriptPage> => {
    const after = rows.filter((row) => row.seq > afterSeq);
    const page = after.slice(0, pageSize ?? limit);
    return { rows: page, hasMore: after.length > page.length, lastSeq: page.length > 0 ? page[page.length - 1]!.seq : null };
  };
}

function searchSeqs(deep: DeepIndexDbHandle, query: string): number[] {
  return deep.searchMessages({ query, scope: { type: 'global' }, limit: 50, offset: 0 }).hits.map((hit) => hit.seq);
}

describe('syncDeepIndexForSessionsOnce', () => {
  let dir: string;
  let tier1: SummaryShardIndexDbHandle;
  let deep: DeepIndexDbHandle;

  beforeEach(async () => {
    dir = await mkdtemp(join(os.tmpdir(), 'happier-memory-deep-sync-'));
    tier1 = openSummaryShardIndexDb({ dbPath: join(dir, 'memory.sqlite') });
    tier1.init();
    deep = openDeepIndexDb({ dbPath: join(dir, 'deep.sqlite'), accountId: 'acct-1' });
  });

  afterEach(async () => {
    deep.close();
    tier1.close();
    await rm(dir, { recursive: true, force: true });
  });

  it('indexes each user and assistant message on its own seq and leaves tool and usage rows out', async () => {
    const rows = [
      { seq: 1, createdAtMs: 1000, role: 'agent', content: { type: 'codex', data: { type: 'token_count' } }, meta: null },
      { seq: 2, createdAtMs: 1001, role: 'agent', content: { type: 'codex', data: { type: 'tool-call', name: 'Bash', input: { command: 'echo forbidden-tool-text' } } }, meta: null },
      { seq: 3, createdAtMs: 1002, role: 'agent', content: { type: 'codex', data: { type: 'message', message: 'codex assistant described sapphire indexing' } }, meta: null },
      { seq: 4, createdAtMs: 1003, role: 'agent', content: { type: 'output', data: { message: { role: 'assistant', content: [{ type: 'text', text: 'claude output described orchard retrieval' }] } } }, meta: null },
      { seq: 5, createdAtMs: 1004, role: 'user', content: { type: 'text', text: 'where is the orchard?' }, meta: null },
    ] satisfies DecryptedTranscriptRow[];

    await syncDeepIndexForSessionsOnce({
      sessionIds: ['sess-1'],
      tier1,
      deep,
      now: () => 10_000,
      settings: BASE_SETTINGS,
      fetchDecryptedTranscriptPageAfterSeq: pageFrom(rows),
    });

    expect(searchSeqs(deep, 'sapphire')).toEqual([3]);
    expect(searchSeqs(deep, 'orchard').sort()).toEqual([4, 5]);
    expect(searchSeqs(deep, 'forbidden')).toEqual([]);
    const user = deep.searchMessages({ query: 'where', scope: { type: 'global' }, limit: 5, offset: 0 }).hits[0];
    expect(user).toMatchObject({ seq: 5, role: 'user', createdAtMs: 1004 });
    expect(tier1.getSessionCursors({ sessionId: 'sess-1', nowMs: 10_000 }).lastDeepIndexedSeq).toBe(5);
  });

  it('skips ACP and Codex assistant payload content when includeAssistantAcpMessage is false', async () => {
    const rows = [
      { seq: 1, createdAtMs: 1000, role: 'agent', content: { type: 'acp', data: { type: 'message', message: 'hidden acp answer' } }, meta: null },
      { seq: 2, createdAtMs: 1001, role: 'agent', content: { type: 'codex', data: { type: 'message', message: 'hidden codex answer' } }, meta: null },
      { seq: 3, createdAtMs: 1002, role: 'agent', content: { type: 'acp', data: { type: 'reasoning', message: 'hidden acp reasoning trace' } }, meta: null },
      { seq: 4, createdAtMs: 1003, role: 'agent', content: { type: 'text', text: 'plain assistant answer stays indexed' }, meta: null },
      { seq: 5, createdAtMs: 1004, role: 'user', content: { type: 'text', text: 'user memory stays indexed' }, meta: null },
    ] satisfies DecryptedTranscriptRow[];

    await syncDeepIndexForSessionsOnce({
      sessionIds: ['sess-gated'],
      tier1,
      deep,
      now: () => 10_000,
      settings: {
        ...BASE_SETTINGS,
        contentPolicy: {
          includeUserMessages: true,
          includeAssistantMessages: true,
          includeReasoning: true,
          includeToolSummaries: false,
          includeToolOutputs: false,
        },
        deep: { ...BASE_SETTINGS.deep, includeAssistantAcpMessage: false },
      },
      fetchDecryptedTranscriptPageAfterSeq: pageFrom(rows),
    });

    expect(searchSeqs(deep, 'hidden')).toEqual([]);
    expect(searchSeqs(deep, 'plain assistant')).toEqual([4]);
    expect(searchSeqs(deep, 'user memory')).toEqual([5]);
  });

  it('resumes each session from its cursor, one page per pass, without duplicating messages', async () => {
    const rows = Array.from({ length: 5 }, (_, index) => ({
      seq: index + 1,
      createdAtMs: 1000 + index,
      role: 'user' as const,
      content: { type: 'text', text: `resumable message ${index + 1}` },
      meta: null,
    })) satisfies DecryptedTranscriptRow[];
    const fetch = pageFrom(rows, 2);

    for (let pass = 1; pass <= 4; pass += 1) {
      await syncDeepIndexForSessionsOnce({
        sessionIds: ['sess-1'],
        tier1,
        deep,
        now: () => 10_000 * pass,
        settings: BASE_SETTINGS,
        fetchDecryptedTranscriptPageAfterSeq: fetch,
      });
      expect(tier1.getSessionCursors({ sessionId: 'sess-1', nowMs: 10_000 * pass }).lastDeepIndexedSeq).toBe(Math.min(5, pass * 2));
    }

    expect(searchSeqs(deep, 'resumable').sort()).toEqual([1, 2, 3, 4, 5]);
    expect(deep.getDeepIndexStats().deepChunkCount).toBe(5);
  });

  it('marks a session read up to its observed seq once the server has no more of its messages', async () => {
    const rows = [
      { seq: 1, createdAtMs: 1000, role: 'user', content: { type: 'text', text: 'only text message' }, meta: null },
    ] satisfies DecryptedTranscriptRow[];

    await syncDeepIndexForSessionsOnce({
      sessionIds: ['sess-events'],
      observedSeqBySessionId: new Map([['sess-events', 9]]),
      tier1,
      deep,
      now: () => 10_000,
      settings: BASE_SETTINGS,
      fetchDecryptedTranscriptPageAfterSeq: pageFrom(rows),
    });

    expect(tier1.getSessionCursors({ sessionId: 'sess-events', nowMs: 10_000 }).lastDeepIndexedSeq).toBe(9);
  });

  it('moves past rows it could not decrypt instead of reading them again forever', async () => {
    await syncDeepIndexForSessionsOnce({
      sessionIds: ['sess-1'],
      observedSeqBySessionId: new Map([['sess-1', 50]]),
      tier1,
      deep,
      now: () => 10_000,
      settings: BASE_SETTINGS,
      fetchDecryptedTranscriptPageAfterSeq: async () => ({
        rows: [{ seq: 1, createdAtMs: 1000, role: 'user', content: { type: 'text', text: 'readable' }, meta: null }],
        hasMore: true,
        lastSeq: 3,
      }),
    });

    expect(tier1.getSessionCursors({ sessionId: 'sess-1', nowMs: 10_000 }).lastDeepIndexedSeq).toBe(3);
  });

  it('records queue telemetry for indexed deep sessions', async () => {
    const rows = [
      { seq: 1, createdAtMs: 1000, role: 'user', content: { type: 'text', text: 'deep telemetry openclaw' }, meta: null },
      { seq: 2, createdAtMs: 1001, role: 'agent', content: { type: 'text', text: 'deep queue metrics' }, meta: null },
    ] satisfies DecryptedTranscriptRow[];

    await syncDeepIndexForSessionsOnce({
      sessionIds: ['sess-telemetry'],
      tier1,
      deep,
      now: () => 10_000,
      settings: BASE_SETTINGS,
      fetchDecryptedTranscriptPageAfterSeq: pageFrom(rows),
    });

    expect(tier1.getMemoryIndexQueueTelemetry()).toMatchObject({
      selectedSessionCount: 1,
      indexedSessionCount: 1,
      rawRowsFetched: 2,
      semanticRowsFound: 2,
      semanticRowsIndexedDeep: 2,
      deepChunkCount: 2,
      lastRun: expect.objectContaining({
        indexMode: 'deep',
        sessionsConsidered: 1,
        sessionsProcessed: 1,
        sessionsIndexed: 1,
        rawRowsFetched: 2,
        semanticRowsFound: 2,
        deepChunksCreated: 2,
      }),
    });
  });

  it('stores one embedding per new message, and backfills messages indexed before embeddings were on', async () => {
    const rows = [
      { seq: 1, createdAtMs: 1000, role: 'user', content: { type: 'text', text: 'hello openclaw' }, meta: null },
      { seq: 2, createdAtMs: 1001, role: 'agent', content: { type: 'text', text: 'deep index is useful' }, meta: null },
    ] satisfies DecryptedTranscriptRow[];

    await syncDeepIndexForSessionsOnce({
      sessionIds: ['sess-1'],
      tier1,
      deep,
      now: () => 10_000,
      settings: BASE_SETTINGS,
      fetchDecryptedTranscriptPageAfterSeq: pageFrom(rows),
    });
    expect(deep.loadEmbeddings({ provider: 'test', modelId: 'm1', keys: [{ sessionId: 'sess-1', seq: 1 }] }).size).toBe(0);

    const embedded: string[][] = [];
    await syncDeepIndexForSessionsOnce({
      sessionIds: ['sess-1'],
      tier1,
      deep,
      now: () => 20_000,
      settings: { ...BASE_SETTINGS, embeddings: TEST_EMBEDDINGS },
      embedDocuments: async (texts) => {
        embedded.push([...texts]);
        return texts.map(() => new Float32Array([0.25, 0.5]));
      },
      fetchDecryptedTranscriptPageAfterSeq: async () => ({ rows: [], hasMore: false, lastSeq: null }),
    });

    expect(embedded).toEqual([['hello openclaw', 'deep index is useful']]);
    const map = deep.loadEmbeddings({
      provider: 'test',
      modelId: 'm1',
      keys: [{ sessionId: 'sess-1', seq: 1 }, { sessionId: 'sess-1', seq: 2 }],
    });
    expect([...map.keys()].sort()).toEqual(['sess-1:1', 'sess-1:2']);
  });
});

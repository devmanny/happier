import { describe, expect, it } from 'vitest';

import {
  MEMORY_SEARCH_V2_DEFAULT_LIMIT,
  MEMORY_SEARCH_V2_MAX_LIMIT,
  MemorySearchErrorCodeSchema,
  MemorySearchHitV2Schema,
  MemorySearchQueryV1Schema,
  MemorySearchQueryV2Schema,
  MemorySearchResultV1Schema,
  MemorySearchResultV2Schema,
} from './memorySearch.js';

describe('memory_search_result.v1 schema', () => {
  it('parses a success result', () => {
    const parsed = MemorySearchResultV1Schema.parse({
      v: 1,
      ok: true,
      hits: [
        {
          sessionId: 'sess_1',
          seqFrom: 10,
          seqTo: 25,
          createdAtFromMs: 1000,
          createdAtToMs: 2000,
          summary: 'We discussed OpenClaw memory indexing.',
          score: 0.42,
        },
      ],
    });
    expect(parsed.ok).toBe(true);
    expect((parsed as any).hits).toHaveLength(1);
  });

  it('parses an empty success result for a valid searchable index with no hits', () => {
    const parsed = MemorySearchResultV1Schema.parse({
      v: 1,
      ok: true,
      hits: [],
    });

    expect(parsed.ok).toBe(true);
    if (parsed.ok) {
      expect(parsed.hits).toEqual([]);
    }
  });

  it('parses a failure result with stable error codes', () => {
    expect(MemorySearchErrorCodeSchema.parse('memory_disabled')).toBe('memory_disabled');
    const parsed = MemorySearchResultV1Schema.parse({
      v: 1,
      ok: false,
      errorCode: 'memory_disabled',
      error: 'Memory search is disabled.',
    });
    expect(parsed.ok).toBe(false);
  });
});

describe('MemorySearchQueryV1Schema', () => {
  it('parses a basic query', () => {
    const parsed = MemorySearchQueryV1Schema.parse({
      v: 1,
      query: 'openclaw',
      scope: { type: 'global' },
      mode: 'auto',
      maxResults: 20,
      minScore: 0.15,
    });
    expect(parsed.query).toBe('openclaw');
  });
});

describe('memory message search (v2)', () => {
  const hit = {
    sessionId: 'sess_1',
    seq: 42,
    createdAtMs: 1_700_000_000_000,
    role: 'assistant',
    snippet: [
      { text: 'Configuramos la ', match: false },
      { text: 'búsqueda', match: true },
      { text: ' en el Mac…', match: false },
    ],
    score: 7.25,
    session: { title: 'Relay migration', agent: 'claude' },
  };

  it('defaults scope and page size, and keeps the cursor opaque', () => {
    const parsed = MemorySearchQueryV2Schema.parse({ v: 2, query: '  búsqueda relay ' });
    expect(parsed.query).toBe('búsqueda relay');
    expect(parsed.scope).toEqual({ type: 'global' });
    expect(parsed.limit).toBe(MEMORY_SEARCH_V2_DEFAULT_LIMIT);

    const next = MemorySearchQueryV2Schema.parse({ v: 2, query: 'relay', cursor: 'o:20', limit: MEMORY_SEARCH_V2_MAX_LIMIT });
    expect(next.cursor).toBe('o:20');
  });

  it('ranks by relevance unless the newest messages are asked for first', () => {
    expect(MemorySearchQueryV2Schema.parse({ v: 2, query: 'relay' }).order).toBe('relevance');
    expect(MemorySearchQueryV2Schema.parse({ v: 2, query: 'relay', order: 'recent' }).order).toBe('recent');
    expect(MemorySearchQueryV2Schema.safeParse({ v: 2, query: 'relay', order: 'oldest' }).success).toBe(false);
  });

  it('rejects blank queries and pages beyond the limit', () => {
    expect(MemorySearchQueryV2Schema.safeParse({ v: 2, query: '   ' }).success).toBe(false);
    expect(MemorySearchQueryV2Schema.safeParse({ v: 2, query: 'x', limit: MEMORY_SEARCH_V2_MAX_LIMIT + 1 }).success).toBe(false);
  });

  it('is refused by the v1 query schema, which is how an older daemon answers a v2 request', () => {
    expect(MemorySearchQueryV1Schema.safeParse({ v: 2, query: 'relay', scope: { type: 'global' } }).success).toBe(false);
  });

  it('parses a page of message hits with coverage', () => {
    const parsed = MemorySearchResultV2Schema.parse({
      v: 2,
      ok: true,
      hits: [hit],
      nextCursor: 'o:20',
      coverage: { messageCount: 1200, sessionCount: 40, knownSessionCount: 45, pendingSessionCount: 3, backfillComplete: false },
    });
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    expect(parsed.hits[0]?.seq).toBe(42);
    expect(parsed.hits[0]?.snippet.filter((segment) => segment.match).map((segment) => segment.text)).toEqual(['búsqueda']);
    expect(parsed.nextCursor).toBe('o:20');
  });

  it('accepts unknown session title and agent, but not a hit without snippet text', () => {
    expect(MemorySearchHitV2Schema.safeParse({ ...hit, session: { title: null, agent: null } }).success).toBe(true);
    expect(MemorySearchHitV2Schema.safeParse({ ...hit, snippet: [] }).success).toBe(false);
  });

  it('parses failures with the shared error codes', () => {
    const parsed = MemorySearchResultV2Schema.parse({ v: 2, ok: false, errorCode: 'memory_index_missing', error: 'memory_index_missing' });
    expect(parsed.ok).toBe(false);
  });
});

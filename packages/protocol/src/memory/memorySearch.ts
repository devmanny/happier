import { z } from 'zod';

export const MemorySearchScopeSchema = z.discriminatedUnion('type', [
  z.object({ type: z.literal('global') }).passthrough(),
  z.object({ type: z.literal('session'), sessionId: z.string().min(1) }).passthrough(),
]);
export type MemorySearchScope = z.infer<typeof MemorySearchScopeSchema>;

export const MemorySearchModeSchema = z.enum(['hints', 'deep', 'auto']);
export type MemorySearchMode = z.infer<typeof MemorySearchModeSchema>;

// Stable error code vocabulary for memory RPC + action surfaces.
export const MemorySearchErrorCodeSchema = z.enum([
  'memory_disabled',
  'memory_key_unavailable',
  'memory_index_missing',
  'memory_invalid_query',
  'memory_failed',
]);
export type MemorySearchErrorCode = z.infer<typeof MemorySearchErrorCodeSchema>;

export const MemoryCitationV1Schema = z.object({
  sessionId: z.string().min(1),
  seqFrom: z.number().int().min(0),
  seqTo: z.number().int().min(0),
}).passthrough().superRefine((value, ctx) => {
  if (value.seqFrom > value.seqTo) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'seqFrom must be <= seqTo', path: ['seqFrom'] });
  }
});
export type MemoryCitationV1 = z.infer<typeof MemoryCitationV1Schema>;

export const MemorySearchHitV1Schema = z.object({
  sessionId: z.string().min(1),
  seqFrom: z.number().int().min(0),
  seqTo: z.number().int().min(0),
  createdAtFromMs: z.number().int().min(0),
  createdAtToMs: z.number().int().min(0),
  summary: z.string().min(1),
  score: z.number().min(0).max(1),
}).passthrough().superRefine((value, ctx) => {
  if (value.seqFrom > value.seqTo) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'seqFrom must be <= seqTo', path: ['seqFrom'] });
  }
  if (value.createdAtFromMs > value.createdAtToMs) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'createdAtFromMs must be <= createdAtToMs', path: ['createdAtFromMs'] });
  }
});
export type MemorySearchHitV1 = z.infer<typeof MemorySearchHitV1Schema>;

export const MemorySearchQueryV1Schema = z.object({
  v: z.literal(1),
  query: z.string().min(1),
  scope: MemorySearchScopeSchema,
  mode: MemorySearchModeSchema,
  maxResults: z.number().int().min(1).max(100).optional(),
  minScore: z.number().min(0).max(1).optional(),
}).passthrough();
export type MemorySearchQueryV1 = z.infer<typeof MemorySearchQueryV1Schema>;

export const MemorySearchResultV1Schema = z.union([
  z.object({
    v: z.literal(1),
    ok: z.literal(true),
    hits: z.array(MemorySearchHitV1Schema),
  }).passthrough(),
  z.object({
    v: z.literal(1),
    ok: z.literal(false),
    errorCode: MemorySearchErrorCodeSchema,
    error: z.string().min(1),
  }).passthrough(),
]);
export type MemorySearchResultV1 = z.infer<typeof MemorySearchResultV1Schema>;

/**
 * Full-text message search (v2), served by the daemon's deep index over the same RPC method
 * as v1 (`daemon.memory.search`); `v` selects the request and result shape. Each hit is ONE
 * transcript message (user or assistant text), ranked by BM25, so a client can open the
 * session at `seq`. A daemon that predates v2 refuses the request with
 * `{ v: 1, ok: false, errorCode: 'memory_invalid_query' }`: clients read `v: 1` as
 * "this daemon has no full-text search yet".
 */
export const MEMORY_SEARCH_V2_DEFAULT_LIMIT = 20;
export const MEMORY_SEARCH_V2_MAX_LIMIT = 50;

/** The snippet as ordered text segments; `match` marks the query terms, so no offsets cross runtimes. */
export const MemorySearchSnippetSegmentV2Schema = z.object({
  text: z.string().min(1),
  match: z.boolean(),
}).passthrough();
export type MemorySearchSnippetSegmentV2 = z.infer<typeof MemorySearchSnippetSegmentV2Schema>;

export const MemorySearchHitV2Schema = z.object({
  sessionId: z.string().min(1),
  seq: z.number().int().min(0),
  createdAtMs: z.number().int().min(0),
  role: z.enum(['user', 'assistant']),
  snippet: z.array(MemorySearchSnippetSegmentV2Schema).min(1),
  /** Relevance, higher is better; comparable only within one result page sequence. */
  score: z.number().min(0),
  /** As last seen by the daemon; `agent` is the session's metadata flavor (e.g. `claude`). */
  session: z.object({
    title: z.string().min(1).nullable(),
    agent: z.string().min(1).nullable(),
  }).passthrough(),
}).passthrough();
export type MemorySearchHitV2 = z.infer<typeof MemorySearchHitV2Schema>;

/** How a page sequence is ordered: best match first, or newest message first. */
export const MemorySearchOrderV2Schema = z.enum(['relevance', 'recent']);
export type MemorySearchOrderV2 = z.infer<typeof MemorySearchOrderV2Schema>;

export const MemorySearchQueryV2Schema = z.object({
  v: z.literal(2),
  query: z.string().trim().min(1).max(500),
  scope: MemorySearchScopeSchema.default({ type: 'global' }),
  /** A daemon from before this field ranks by relevance whatever is asked. */
  order: MemorySearchOrderV2Schema.default('relevance'),
  limit: z.number().int().min(1).max(MEMORY_SEARCH_V2_MAX_LIMIT).default(MEMORY_SEARCH_V2_DEFAULT_LIMIT),
  /** Opaque continuation from the previous page's `nextCursor`. */
  cursor: z.string().min(1).max(200).nullable().optional(),
}).passthrough();
export type MemorySearchQueryV2 = z.infer<typeof MemorySearchQueryV2Schema>;

/** How much of the account the index covers right now (the history backfill runs in the background). */
export const MemorySearchCoverageV2Schema = z.object({
  messageCount: z.number().int().nonnegative(),
  /** Sessions with at least one indexed message. */
  sessionCount: z.number().int().nonnegative(),
  /** Sessions the daemon has listed so far. */
  knownSessionCount: z.number().int().nonnegative(),
  /** Known sessions with messages the index has not read yet. */
  pendingSessionCount: z.number().int().nonnegative(),
  /** Every known session has been listed and read up to its latest message. */
  backfillComplete: z.boolean(),
}).passthrough();
export type MemorySearchCoverageV2 = z.infer<typeof MemorySearchCoverageV2Schema>;

export const MemorySearchResultV2Schema = z.union([
  z.object({
    v: z.literal(2),
    ok: z.literal(true),
    hits: z.array(MemorySearchHitV2Schema),
    nextCursor: z.string().min(1).nullable(),
    coverage: MemorySearchCoverageV2Schema,
  }).passthrough(),
  z.object({
    v: z.literal(2),
    ok: z.literal(false),
    errorCode: MemorySearchErrorCodeSchema,
    error: z.string().min(1),
  }).passthrough(),
]);
export type MemorySearchResultV2 = z.infer<typeof MemorySearchResultV2Schema>;

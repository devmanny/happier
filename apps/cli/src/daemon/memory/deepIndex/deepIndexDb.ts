import { chmodSync, closeSync, openSync } from 'node:fs';

import type { MemorySearchSnippetSegmentV2 } from '@happier-dev/protocol';

import { openSqliteDatabaseSync, type SqliteDatabaseSync } from '@/utils/sqlite/sqliteSync';

import type {
  MemoryIndexableTranscriptKind,
  MemoryIndexableTranscriptRole,
} from '../semanticTranscript/memoryIndexableTranscriptItem';

/**
 * The deep memory index: one row per transcript message the content policy admits (user and
 * assistant text by default; `kind` leaves room for tool output), searched through SQLite FTS5
 * with BM25 ranking and highlighted snippets. Rows are keyed by `(sessionId, seq)`, so reading
 * the same transcript page again updates rows instead of duplicating them.
 *
 * The file holds decrypted conversation text: it is created 0600 and is bound to one account.
 * Opening it for another account, or finding an older schema, rebuilds it empty (`rebuilt`),
 * and the caller restarts the per-session read cursors from the beginning.
 */

const SCHEMA_VERSION = 2;
const SNIPPET_MATCH_START = '\u0002';
const SNIPPET_MATCH_END = '\u0003';
const SNIPPET_TOKENS = 24;
const MIN_PREFIX_TERM_CHARS = 3;
const MAX_QUERY_TERMS = 16;

export type DeepIndexSearchScope =
  | Readonly<{ type: 'global' }>
  | Readonly<{ type: 'session'; sessionId: string }>;

export type DeepIndexMessage = Readonly<{
  seq: number;
  createdAtMs: number;
  role: MemoryIndexableTranscriptRole;
  kind: MemoryIndexableTranscriptKind;
  text: string;
}>;

export type DeepIndexSessionMeta = Readonly<{
  title: string | null;
  agent: string | null;
}>;

export type DeepIndexMessageHit = Readonly<{
  sessionId: string;
  seq: number;
  createdAtMs: number;
  role: MemoryIndexableTranscriptRole;
  text: string;
  snippet: MemorySearchSnippetSegmentV2[];
  /** `-bm25`: higher is more relevant. */
  score: number;
  session: DeepIndexSessionMeta;
}>;

export type DeepIndexStats = Readonly<{
  /** Indexed messages (the deep index's unit; the field name predates per-message rows). */
  deepChunkCount: number;
  deepEmbeddingCount: number;
  searchableSessionCount: number;
  latestIndexedMessageAtMs: number | null;
}>;

export type DeepIndexMessageKey = Readonly<{ sessionId: string; seq: number }>;

export type DeepIndexDbHandle = Readonly<{
  /** True when this open created the index from nothing: new file, older schema or another account. */
  rebuilt: boolean;
  upsertMessages: (args: Readonly<{ sessionId: string; messages: ReadonlyArray<DeepIndexMessage> }>) => number;
  upsertSessionMeta: (args: Readonly<{ sessionId: string } & DeepIndexSessionMeta>) => void;
  searchMessages: (args: Readonly<{
    query: string;
    scope: DeepIndexSearchScope;
    limit: number;
    offset: number;
  }>) => Readonly<{ hits: DeepIndexMessageHit[]; hasMore: boolean }>;
  upsertEmbedding: (args: Readonly<DeepIndexMessageKey & {
    provider: string;
    modelId: string;
    embedding: Float32Array;
    updatedAtMs: number;
  }>) => void;
  loadEmbeddings: (args: Readonly<{
    provider: string;
    modelId: string;
    keys: ReadonlyArray<DeepIndexMessageKey>;
  }>) => Map<string, Float32Array>;
  listMessagesWithoutEmbeddings: (args: Readonly<{
    sessionId: string;
    provider: string;
    modelId: string;
    limit: number;
  }>) => ReadonlyArray<Readonly<DeepIndexMessageKey & { text: string }>>;
  getDeepIndexStats: () => DeepIndexStats;
  deleteOldestMessages: (args: Readonly<{ limit: number }>) => number;
  checkpointAndVacuum: () => void;
  close: () => void;
}>;

export function deepIndexMessageKey(key: DeepIndexMessageKey): string {
  return `${key.sessionId}:${key.seq}`;
}

/**
 * The user's words as an FTS5 query: every word must match, as a quoted phrase (so FTS syntax in
 * the input stays literal) and as a prefix once it is long enough to be selective.
 */
export function buildDeepIndexMatchQuery(raw: string): string | null {
  const terms = String(raw ?? '')
    .split(/\s+/u)
    .map((term) => term.replace(/"/g, ''))
    .filter((term) => /[\p{L}\p{N}]/u.test(term))
    .slice(0, MAX_QUERY_TERMS);
  if (terms.length === 0) return null;
  return terms
    .map((term) => {
      const letters = term.replace(/[^\p{L}\p{N}]/gu, '');
      return letters.length >= MIN_PREFIX_TERM_CHARS ? `"${term}"*` : `"${term}"`;
    })
    .join(' ');
}

function sanitizeIndexedText(text: string): string {
  return text.replace(/[\u0002\u0003]/g, '').trim();
}

function parseSnippet(raw: string): MemorySearchSnippetSegmentV2[] {
  const segments: MemorySearchSnippetSegmentV2[] = [];
  let rest = raw;
  while (rest.length > 0) {
    const start = rest.indexOf(SNIPPET_MATCH_START);
    if (start < 0) {
      segments.push({ text: rest, match: false });
      break;
    }
    if (start > 0) segments.push({ text: rest.slice(0, start), match: false });
    const end = rest.indexOf(SNIPPET_MATCH_END, start + 1);
    const matched = rest.slice(start + 1, end < 0 ? undefined : end);
    if (matched.length > 0) segments.push({ text: matched, match: true });
    rest = end < 0 ? '' : rest.slice(end + 1);
  }
  return segments.filter((segment) => segment.text.length > 0);
}

function toInt(value: unknown): number {
  const n = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(n) ? Math.max(0, Math.trunc(n)) : 0;
}

function toNullableInt(value: unknown): number | null {
  if (value === null || value === undefined) return null;
  const n = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(n) ? Math.max(0, Math.trunc(n)) : null;
}

function toNullableText(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function createOwnerOnlyFile(path: string): void {
  if (path === ':memory:' || process.platform === 'win32') return;
  try {
    closeSync(openSync(path, 'a', 0o600));
    chmodSync(path, 0o600);
  } catch {
    // SQLite reports a path it cannot open.
  }
}

function readMeta(db: SqliteDatabaseSync, key: string): string | null {
  try {
    const row = db.prepare('SELECT value FROM index_meta WHERE key = ?').get(key) as { value?: unknown } | undefined;
    return typeof row?.value === 'string' ? row.value : null;
  } catch {
    return null;
  }
}

function dropAllTables(db: SqliteDatabaseSync): void {
  const rows = db.prepare(`SELECT name, type FROM sqlite_master WHERE type IN ('table', 'trigger') AND name NOT LIKE 'sqlite_%'`).all() as Array<{ name?: unknown; type?: unknown }>;
  for (const row of rows) {
    if (row.type !== 'trigger' || typeof row.name !== 'string') continue;
    db.exec(`DROP TRIGGER IF EXISTS "${row.name.replace(/"/g, '""')}"`);
  }
  // FTS5 shadow tables go with their virtual table; drop virtual tables first.
  const tables = db.prepare(`SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'`).all() as Array<{ name?: unknown; sql?: unknown }>;
  const ordered = [...tables].sort((left, right) => {
    const leftVirtual = typeof left.sql === 'string' && /CREATE VIRTUAL TABLE/i.test(left.sql) ? 0 : 1;
    const rightVirtual = typeof right.sql === 'string' && /CREATE VIRTUAL TABLE/i.test(right.sql) ? 0 : 1;
    return leftVirtual - rightVirtual;
  });
  for (const table of ordered) {
    if (typeof table.name !== 'string') continue;
    db.exec(`DROP TABLE IF EXISTS "${table.name.replace(/"/g, '""')}"`);
  }
}

function createSchema(db: SqliteDatabaseSync, accountId: string): void {
  db.exec(`
    CREATE TABLE index_meta (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );

    CREATE TABLE messages (
      id INTEGER PRIMARY KEY,
      sessionId TEXT NOT NULL,
      seq INTEGER NOT NULL,
      createdAtMs INTEGER NOT NULL,
      role TEXT NOT NULL,
      kind TEXT NOT NULL,
      text TEXT NOT NULL,
      UNIQUE (sessionId, seq)
    );
    CREATE INDEX messages_by_created ON messages(createdAtMs);

    CREATE VIRTUAL TABLE messages_fts USING fts5(
      text,
      content = 'messages',
      content_rowid = 'id',
      tokenize = 'unicode61 remove_diacritics 2'
    );
    CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN
      INSERT INTO messages_fts(rowid, text) VALUES (new.id, new.text);
    END;
    CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN
      INSERT INTO messages_fts(messages_fts, rowid, text) VALUES ('delete', old.id, old.text);
    END;
    CREATE TRIGGER messages_au AFTER UPDATE OF text ON messages BEGIN
      INSERT INTO messages_fts(messages_fts, rowid, text) VALUES ('delete', old.id, old.text);
      INSERT INTO messages_fts(rowid, text) VALUES (new.id, new.text);
    END;

    CREATE TABLE sessions (
      sessionId TEXT PRIMARY KEY,
      title TEXT,
      agent TEXT
    );

    CREATE TABLE message_embeddings (
      sessionId TEXT NOT NULL,
      seq INTEGER NOT NULL,
      provider TEXT NOT NULL,
      modelId TEXT NOT NULL,
      dims INTEGER NOT NULL,
      embedding BLOB NOT NULL,
      updatedAtMs INTEGER NOT NULL,
      PRIMARY KEY (sessionId, seq, provider, modelId)
    );
  `);
  db.prepare('INSERT INTO index_meta (key, value) VALUES (?, ?)').run('accountId', accountId);
  db.exec(`PRAGMA user_version=${SCHEMA_VERSION}`);
}

function ensureSchema(db: SqliteDatabaseSync, accountId: string): boolean {
  const versionRow = db.prepare('PRAGMA user_version').get() as { user_version?: unknown } | undefined;
  const userVersion = toInt(versionRow?.user_version);
  if (userVersion === SCHEMA_VERSION && readMeta(db, 'accountId') === accountId) return false;

  db.exec('BEGIN IMMEDIATE');
  try {
    dropAllTables(db);
    createSchema(db, accountId);
    db.exec('COMMIT');
  } catch (error) {
    db.exec('ROLLBACK');
    throw error;
  }
  db.exec('VACUUM');
  return true;
}

export function openDeepIndexDb(args: Readonly<{ dbPath: string; accountId: string }>): DeepIndexDbHandle {
  createOwnerOnlyFile(args.dbPath);
  const db = openSqliteDatabaseSync(args.dbPath);
  db.exec(`PRAGMA auto_vacuum=INCREMENTAL;`);
  db.exec(`PRAGMA journal_mode=WAL;`);
  db.exec(`PRAGMA synchronous=NORMAL;`);
  const rebuilt = ensureSchema(db, String(args.accountId ?? ''));

  const upsertMessageStmt = db.prepare(`
    INSERT INTO messages (sessionId, seq, createdAtMs, role, kind, text)
    VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(sessionId, seq) DO UPDATE SET
      createdAtMs = excluded.createdAtMs,
      role = excluded.role,
      kind = excluded.kind,
      text = excluded.text
    WHERE messages.text IS NOT excluded.text
       OR messages.role IS NOT excluded.role
       OR messages.kind IS NOT excluded.kind
       OR messages.createdAtMs IS NOT excluded.createdAtMs;
  `);
  const upsertSessionStmt = db.prepare(`
    INSERT INTO sessions (sessionId, title, agent) VALUES (?, ?, ?)
    ON CONFLICT(sessionId) DO UPDATE SET title = excluded.title, agent = excluded.agent
    WHERE sessions.title IS NOT excluded.title OR sessions.agent IS NOT excluded.agent;
  `);
  const statsStmt = db.prepare(`
    SELECT COUNT(*) AS messageCount, COUNT(DISTINCT sessionId) AS sessionCount, MAX(createdAtMs) AS latestAtMs
    FROM messages;
  `);
  const embeddingCountStmt = db.prepare(`SELECT COUNT(*) AS n FROM message_embeddings;`);
  const deleteOldestStmt = db.prepare(`
    DELETE FROM messages WHERE id IN (SELECT id FROM messages ORDER BY createdAtMs ASC, id ASC LIMIT ?);
  `);
  const deleteOrphanEmbeddingsStmt = db.prepare(`
    DELETE FROM message_embeddings
    WHERE NOT EXISTS (
      SELECT 1 FROM messages m WHERE m.sessionId = message_embeddings.sessionId AND m.seq = message_embeddings.seq
    );
  `);
  const upsertEmbeddingStmt = db.prepare(`
    INSERT INTO message_embeddings (sessionId, seq, provider, modelId, dims, embedding, updatedAtMs)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(sessionId, seq, provider, modelId) DO UPDATE SET
      dims = excluded.dims, embedding = excluded.embedding, updatedAtMs = excluded.updatedAtMs;
  `);
  const listWithoutEmbeddingsStmt = db.prepare(`
    SELECT m.sessionId AS sessionId, m.seq AS seq, m.text AS text
    FROM messages m
    LEFT JOIN message_embeddings e
      ON e.sessionId = m.sessionId AND e.seq = m.seq AND e.provider = ? AND e.modelId = ?
    WHERE m.sessionId = ? AND e.sessionId IS NULL
    ORDER BY m.seq ASC
    LIMIT ?;
  `);
  const searchSql = (scoped: boolean) => `
    SELECT
      m.sessionId AS sessionId,
      m.seq AS seq,
      m.createdAtMs AS createdAtMs,
      m.role AS role,
      m.text AS text,
      snippet(messages_fts, 0, '${SNIPPET_MATCH_START}', '${SNIPPET_MATCH_END}', '…', ${SNIPPET_TOKENS}) AS snippet,
      bm25(messages_fts) AS rank,
      s.title AS title,
      s.agent AS agent
    FROM messages_fts
      JOIN messages m ON m.id = messages_fts.rowid
      LEFT JOIN sessions s ON s.sessionId = m.sessionId
    WHERE messages_fts MATCH ?
      ${scoped ? 'AND m.sessionId = ?' : ''}
    ORDER BY rank ASC, m.createdAtMs DESC, m.id DESC
    LIMIT ? OFFSET ?;
  `;
  const searchGlobalStmt = db.prepare(searchSql(false));
  const searchSessionStmt = db.prepare(searchSql(true));

  const transaction = <T>(work: () => T): T => {
    db.exec('BEGIN IMMEDIATE');
    try {
      const result = work();
      db.exec('COMMIT');
      return result;
    } catch (error) {
      db.exec('ROLLBACK');
      throw error;
    }
  };

  return {
    rebuilt,
    upsertMessages: ({ sessionId, messages }) => {
      const sid = String(sessionId ?? '').trim();
      if (!sid || messages.length === 0) return 0;
      return transaction(() => {
        let changed = 0;
        for (const row of messages) {
          const text = sanitizeIndexedText(String(row.text ?? ''));
          if (!text) continue;
          const res = upsertMessageStmt.run(
            sid,
            toInt(row.seq),
            toInt(row.createdAtMs),
            row.role,
            row.kind,
            text,
          ) as { changes?: unknown } | undefined;
          changed += toInt(res?.changes);
        }
        return changed;
      });
    },
    upsertSessionMeta: ({ sessionId, title, agent }) => {
      const sid = String(sessionId ?? '').trim();
      if (!sid) return;
      upsertSessionStmt.run(sid, toNullableText(title), toNullableText(agent));
    },
    searchMessages: ({ query, scope, limit, offset }) => {
      const match = buildDeepIndexMatchQuery(query);
      if (!match) return { hits: [], hasMore: false };
      const pageSize = Math.max(1, Math.trunc(limit));
      const start = Math.max(0, Math.trunc(offset));
      const rows = (scope.type === 'session'
        ? searchSessionStmt.all(match, String(scope.sessionId ?? '').trim(), pageSize + 1, start)
        : searchGlobalStmt.all(match, pageSize + 1, start)) as Array<Record<string, unknown>>;
      const hits = rows.slice(0, pageSize).map((row): DeepIndexMessageHit => {
        const text = String(row.text ?? '');
        const snippet = parseSnippet(String(row.snippet ?? ''));
        return {
          sessionId: String(row.sessionId),
          seq: toInt(row.seq),
          createdAtMs: toInt(row.createdAtMs),
          role: row.role === 'user' ? 'user' : 'assistant',
          text,
          snippet: snippet.length > 0 ? snippet : [{ text, match: false }],
          score: Math.max(0, -Number(row.rank ?? 0)),
          session: { title: toNullableText(row.title), agent: toNullableText(row.agent) },
        };
      });
      return { hits, hasMore: rows.length > pageSize };
    },
    upsertEmbedding: ({ sessionId, seq, provider, modelId, embedding, updatedAtMs }) => {
      const sid = String(sessionId ?? '').trim();
      const prov = String(provider ?? '').trim();
      const mid = String(modelId ?? '').trim();
      if (!sid || !prov || !mid) return;
      if (!(embedding instanceof Float32Array) || embedding.length === 0) return;
      const blob = Buffer.from(Buffer.from(embedding.buffer, embedding.byteOffset, embedding.byteLength));
      upsertEmbeddingStmt.run(sid, toInt(seq), prov, mid, embedding.length, blob, toInt(updatedAtMs));
    },
    loadEmbeddings: ({ provider, modelId, keys }) => {
      const prov = String(provider ?? '').trim();
      const mid = String(modelId ?? '').trim();
      const map = new Map<string, Float32Array>();
      if (!prov || !mid || keys.length === 0) return map;
      const clauses: string[] = [];
      const params: unknown[] = [prov, mid];
      for (const key of keys) {
        const sid = String(key?.sessionId ?? '').trim();
        if (!sid) continue;
        clauses.push('(sessionId = ? AND seq = ?)');
        params.push(sid, toInt(key.seq));
      }
      if (clauses.length === 0) return map;
      const rows = db.prepare(`
        SELECT sessionId, seq, dims, embedding FROM message_embeddings
        WHERE provider = ? AND modelId = ? AND (${clauses.join(' OR ')});
      `).all(...params) as Array<Record<string, unknown>>;
      for (const row of rows) {
        const dims = toInt(row.dims);
        const blob = row.embedding as Uint8Array | null | undefined;
        if (typeof row.sessionId !== 'string' || dims <= 0 || !blob || blob.length !== dims * 4) continue;
        const bytes = Uint8Array.from(blob);
        map.set(deepIndexMessageKey({ sessionId: row.sessionId, seq: toInt(row.seq) }), new Float32Array(bytes.buffer, bytes.byteOffset, dims));
      }
      return map;
    },
    listMessagesWithoutEmbeddings: ({ sessionId, provider, modelId, limit }) => {
      const sid = String(sessionId ?? '').trim();
      const prov = String(provider ?? '').trim();
      const mid = String(modelId ?? '').trim();
      if (!sid || !prov || !mid) return [];
      const rows = listWithoutEmbeddingsStmt.all(prov, mid, sid, Math.max(1, Math.trunc(limit))) as Array<Record<string, unknown>>;
      return rows
        .map((row) => ({ sessionId: String(row.sessionId ?? ''), seq: toInt(row.seq), text: String(row.text ?? '') }))
        .filter((row) => row.sessionId.length > 0 && row.text.trim().length > 0);
    },
    getDeepIndexStats: () => {
      const stats = statsStmt.get() as Record<string, unknown> | undefined;
      const embeddings = embeddingCountStmt.get() as Record<string, unknown> | undefined;
      return {
        deepChunkCount: toInt(stats?.messageCount),
        deepEmbeddingCount: toInt(embeddings?.n),
        searchableSessionCount: toInt(stats?.sessionCount),
        latestIndexedMessageAtMs: toNullableInt(stats?.latestAtMs),
      };
    },
    deleteOldestMessages: ({ limit }) => {
      const n = Math.max(0, Math.trunc(Number.isFinite(limit) ? limit : 0));
      if (n <= 0) return 0;
      return transaction(() => {
        const res = deleteOldestStmt.run(n) as { changes?: unknown } | undefined;
        deleteOrphanEmbeddingsStmt.run();
        return toInt(res?.changes);
      });
    },
    checkpointAndVacuum: () => {
      db.exec(`PRAGMA wal_checkpoint(TRUNCATE);`);
      db.exec(`PRAGMA incremental_vacuum;`);
    },
    close: () => {
      try {
        db.close();
      } catch {
        // best-effort
      }
    },
  };
}

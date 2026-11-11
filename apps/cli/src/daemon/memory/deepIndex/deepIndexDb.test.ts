import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { mkdtemp, rm, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

import { openSqliteDatabaseSync } from '@/utils/sqlite/sqliteSync';

import { openDeepIndexDb, type DeepIndexMessage } from './deepIndexDb';

function message(seq: number, text: string, overrides: Partial<DeepIndexMessage> = {}): DeepIndexMessage {
  return { seq, createdAtMs: 1_000 + seq, role: 'assistant', kind: 'assistant_message', text, ...overrides };
}

function matchedText(snippet: ReadonlyArray<Readonly<{ text: string; match: boolean }>>): string[] {
  return snippet.filter((segment) => segment.match).map((segment) => segment.text);
}

describe('deepIndexDb (full-text, one row per message)', () => {
  let dir: string;
  let dbPath: string;

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), 'happier-deep-index-'));
    dbPath = join(dir, 'deep.sqlite');
  });

  afterEach(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  it('finds messages regardless of accents and case, with highlighted snippets and session details', () => {
    const db = openDeepIndexDb({ dbPath, accountId: 'acct-1' });
    db.upsertSessionMeta({ sessionId: 's1', title: 'Relay migration', agent: 'claude' });
    db.upsertMessages({
      sessionId: 's1',
      messages: [
        message(1, 'Revisemos la configuración del relay antes de migrar.', { role: 'user', kind: 'user_message' }),
        message(2, 'Nada relevante aquí.'),
      ],
    });

    const page = db.searchMessages({ query: 'CONFIGURACION', scope: { type: 'global' }, limit: 10, offset: 0 });
    expect(page.hits).toHaveLength(1);
    const hit = page.hits[0]!;
    expect(hit).toMatchObject({ sessionId: 's1', seq: 1, role: 'user', createdAtMs: 1_001, session: { title: 'Relay migration', agent: 'claude' } });
    expect(matchedText(hit.snippet)).toEqual(['configuración']);
    expect(hit.snippet.map((segment) => segment.text).join('')).toContain('Revisemos la configuración del relay');
    expect(hit.score).toBeGreaterThan(0);
    db.close();
  });

  it('matches every term, treats the words as prefixes and ignores query syntax', () => {
    const db = openDeepIndexDb({ dbPath, accountId: 'acct-1' });
    db.upsertMessages({
      sessionId: 's1',
      messages: [
        message(1, 'The daemon indexes transcripts in SQLite.'),
        message(2, 'The daemon restarts the runner.'),
        message(3, 'A "quoted" OR NEAR(weird) query* must not break: daemon'),
      ],
    });

    const both = db.searchMessages({ query: 'daemon transcr', scope: { type: 'global' }, limit: 10, offset: 0 });
    expect(both.hits.map((hit) => hit.seq)).toEqual([1]);

    const syntax = db.searchMessages({ query: '"quoted" OR NEAR(weird', scope: { type: 'global' }, limit: 10, offset: 0 });
    expect(syntax.hits.map((hit) => hit.seq)).toEqual([3]);

    expect(db.searchMessages({ query: '*** ()', scope: { type: 'global' }, limit: 10, offset: 0 }).hits).toEqual([]);
    db.close();
  });

  it('is idempotent: re-reading the same messages updates rows instead of duplicating them', () => {
    const db = openDeepIndexDb({ dbPath, accountId: 'acct-1' });
    db.upsertMessages({ sessionId: 's1', messages: [message(5, 'first draft about tokens')] });
    db.upsertMessages({ sessionId: 's1', messages: [message(5, 'final wording about tokens'), message(6, 'more tokens')] });

    const page = db.searchMessages({ query: 'tokens', scope: { type: 'global' }, limit: 10, offset: 0 });
    expect(page.hits.map((hit) => hit.seq).sort()).toEqual([5, 6]);
    expect(db.searchMessages({ query: 'draft', scope: { type: 'global' }, limit: 10, offset: 0 }).hits).toEqual([]);
    expect(db.getDeepIndexStats()).toMatchObject({ deepChunkCount: 2, searchableSessionCount: 1, latestIndexedMessageAtMs: 1_006 });
    db.close();
  });

  it('pages through ranked results and respects session scope', () => {
    const db = openDeepIndexDb({ dbPath, accountId: 'acct-1' });
    for (const sessionId of ['s1', 's2']) {
      db.upsertMessages({
        sessionId,
        messages: Array.from({ length: 5 }, (_, index) => message(index + 1, `quota report number ${index + 1}`)),
      });
    }

    const first = db.searchMessages({ query: 'quota', scope: { type: 'global' }, limit: 4, offset: 0 });
    const second = db.searchMessages({ query: 'quota', scope: { type: 'global' }, limit: 4, offset: 4 });
    const third = db.searchMessages({ query: 'quota', scope: { type: 'global' }, limit: 4, offset: 8 });
    expect([first.hasMore, second.hasMore, third.hasMore]).toEqual([true, true, false]);
    const keys = [...first.hits, ...second.hits, ...third.hits].map((hit) => `${hit.sessionId}:${hit.seq}`);
    expect(new Set(keys).size).toBe(10);

    const scoped = db.searchMessages({ query: 'quota', scope: { type: 'session', sessionId: 's2' }, limit: 50, offset: 0 });
    expect(scoped.hits).toHaveLength(5);
    expect(scoped.hits.every((hit) => hit.sessionId === 's2')).toBe(true);
    db.close();
  });

  it('keeps the index across reopen and rebuilds it for another account or an older schema', () => {
    const first = openDeepIndexDb({ dbPath, accountId: 'acct-1' });
    expect(first.rebuilt).toBe(true);
    first.upsertMessages({ sessionId: 's1', messages: [message(1, 'persisted words')] });
    first.close();

    const again = openDeepIndexDb({ dbPath, accountId: 'acct-1' });
    expect(again.rebuilt).toBe(false);
    expect(again.searchMessages({ query: 'persisted', scope: { type: 'global' }, limit: 10, offset: 0 }).hits).toHaveLength(1);
    again.close();

    const otherAccount = openDeepIndexDb({ dbPath, accountId: 'acct-2' });
    expect(otherAccount.rebuilt).toBe(true);
    expect(otherAccount.searchMessages({ query: 'persisted', scope: { type: 'global' }, limit: 10, offset: 0 }).hits).toEqual([]);
    otherAccount.close();

    const legacyPath = join(dir, 'legacy.sqlite');
    const legacy = openSqliteDatabaseSync(legacyPath);
    legacy.exec(`CREATE TABLE message_chunks (chunkId INTEGER PRIMARY KEY, sessionId TEXT, text TEXT); PRAGMA user_version=1;`);
    legacy.close();
    const migrated = openDeepIndexDb({ dbPath: legacyPath, accountId: 'acct-1' });
    expect(migrated.rebuilt).toBe(true);
    migrated.upsertMessages({ sessionId: 's1', messages: [message(1, 'fresh index')] });
    expect(migrated.searchMessages({ query: 'fresh', scope: { type: 'global' }, limit: 10, offset: 0 }).hits).toHaveLength(1);
    migrated.close();
  });

  it('evicts the oldest messages first and drops them from search', () => {
    const db = openDeepIndexDb({ dbPath, accountId: 'acct-1' });
    db.upsertMessages({ sessionId: 's1', messages: [message(1, 'oldmessageuniq'), message(2, 'newmessageuniq')] });

    expect(db.deleteOldestMessages({ limit: 1 })).toBe(1);
    expect(db.searchMessages({ query: 'oldmessageuniq', scope: { type: 'global' }, limit: 10, offset: 0 }).hits).toEqual([]);
    expect(db.searchMessages({ query: 'newmessageuniq', scope: { type: 'global' }, limit: 10, offset: 0 }).hits).toHaveLength(1);
    db.checkpointAndVacuum();
    db.close();
  });

  it('stores and loads one embedding per message', () => {
    const db = openDeepIndexDb({ dbPath, accountId: 'acct-1' });
    db.upsertMessages({ sessionId: 's1', messages: [message(1, 'openclaw'), message(2, 'second')] });
    expect(db.listMessagesWithoutEmbeddings({ sessionId: 's1', provider: 'test', modelId: 'm1', limit: 10 }).map((row) => row.seq)).toEqual([1, 2]);

    db.upsertEmbedding({ sessionId: 's1', seq: 1, provider: 'test', modelId: 'm1', embedding: new Float32Array([1, 2, 3]), updatedAtMs: 123 });

    const map = db.loadEmbeddings({ provider: 'test', modelId: 'm1', keys: [{ sessionId: 's1', seq: 1 }] });
    expect(Array.from(map.get('s1:1') ?? [])).toEqual([1, 2, 3]);
    expect(db.listMessagesWithoutEmbeddings({ sessionId: 's1', provider: 'test', modelId: 'm1', limit: 10 }).map((row) => row.seq)).toEqual([2]);
    db.close();
  });

  it('creates the database file readable only by its owner', async () => {
    if (process.platform === 'win32') return;
    openDeepIndexDb({ dbPath, accountId: 'acct-1' }).close();
    expect((await stat(dbPath)).mode & 0o777).toBe(0o600);
  });
});

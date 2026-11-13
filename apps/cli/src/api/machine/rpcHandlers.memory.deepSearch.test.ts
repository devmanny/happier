import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { mkdtemp, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

import { DEFAULT_MEMORY_SETTINGS, MemorySearchResultV2Schema, type MemorySettingsV1 } from '@happier-dev/protocol';
import { RPC_METHODS } from '@happier-dev/protocol/rpc';

import { openDeepIndexDb, type DeepIndexDbHandle } from '@/daemon/memory/deepIndex/deepIndexDb';
import type { MemoryWorkerHandle } from '@/daemon/memory/memoryWorker';
import { registerMachineMemoryRpcHandlers } from './rpcHandlers.memory';

const DEEP_SETTINGS: MemorySettingsV1 = { ...DEFAULT_MEMORY_SETTINGS, enabled: true, enabledAtMs: 1, indexMode: 'deep' };
const COVERAGE = { messageCount: 3, sessionCount: 2, knownSessionCount: 3, pendingSessionCount: 1, backfillComplete: false };

// The worker owns indexing lifecycle; these handler tests give it a real deep index and settings.
function workerFor(params: Readonly<{ deep: DeepIndexDbHandle | null; settings: MemorySettingsV1; dbPath: string }>): MemoryWorkerHandle {
  return {
    stop: () => {},
    reloadSettings: async () => {},
    ensureUpToDate: async () => {},
    getEmbeddingsDiagnostics: () => ({
      mode: params.settings.embeddings.mode,
      presetId: params.settings.embeddings.mode === 'preset' ? params.settings.embeddings.presetId : null,
      providerKind: params.settings.embeddings.mode === 'preset' ? 'local_transformers' : null,
      modelId: params.settings.embeddings.mode === 'preset' ? 'Xenova/all-MiniLM-L6-v2' : null,
      runtimeState: 'unavailable',
      usingFallback: false,
    }),
    getSettings: () => params.settings,
    getTier1DbPath: () => null,
    getDeepDbPath: () => (params.deep ? params.dbPath : null),
    getDeepIndex: () => params.deep,
    getDeepIndexCoverage: () => COVERAGE,
    getMessageSearchStatus: async () => ({ v: 1, enabled: params.deep !== null, state: params.deep ? 'indexing' : 'off', coverage: params.deep ? COVERAGE : null, indexBytes: null }),
    setMessageSearch: async (request) => ({ v: 1, enabled: request.enabled, state: request.enabled ? 'indexing' : 'off', coverage: null, indexBytes: null }),
  };
}

function registerHandlers(memoryWorker: MemoryWorkerHandle): Map<string, (raw: unknown) => Promise<unknown>> {
  const handlers = new Map<string, (raw: unknown) => Promise<unknown>>();
  registerMachineMemoryRpcHandlers({
    rpcHandlerManager: {
      registerHandler: (method: string, handler: (params: unknown) => Promise<unknown>) => {
        handlers.set(method, handler);
      },
    } as never,
    memoryWorker,
  });
  return handlers;
}

function registerSearch(memoryWorker: MemoryWorkerHandle): (raw: unknown) => Promise<unknown> {
  const handlers = new Map<string, (raw: unknown) => Promise<unknown>>();
  registerMachineMemoryRpcHandlers({
    rpcHandlerManager: {
      registerHandler: (method: string, handler: (params: unknown) => Promise<unknown>) => {
        handlers.set(method, handler);
      },
    } as never,
    memoryWorker,
  });
  const handler = handlers.get(RPC_METHODS.DAEMON_MEMORY_SEARCH);
  if (!handler) throw new Error('memory search handler was not registered');
  return handler;
}

describe('rpcHandlers.memory (deep search routing)', () => {
  let dir: string;
  let dbPath: string;
  let deep: DeepIndexDbHandle;

  beforeEach(async () => {
    vi.resetModules();
    dir = await mkdtemp(join(tmpdir(), 'happier-rpc-memory-deep-'));
    dbPath = join(dir, 'deep.sqlite');
    deep = openDeepIndexDb({ dbPath, accountId: 'acct-1' });
    deep.upsertSessionMeta({ sessionId: 's1', title: 'Memory plan', agent: 'claude' });
    deep.upsertMessages({
      sessionId: 's1',
      messages: [
        { seq: 3, createdAtMs: 30, role: 'user', kind: 'user_message', text: 'We discussed Openclaw and deep memory search.' },
        { seq: 4, createdAtMs: 40, role: 'assistant', kind: 'assistant_message', text: 'Openclaw indexes banana-embeddings-qa locally.' },
      ],
    });
    deep.upsertMessages({
      sessionId: 's2',
      messages: [{ seq: 9, createdAtMs: 90, role: 'assistant', kind: 'assistant_message', text: 'Openclaw again, in another session.' }],
    });
  });

  afterEach(async () => {
    deep.close();
    vi.resetModules();
    vi.unmock('@huggingface/transformers');
    await rm(dir, { recursive: true, force: true });
  });

  it('routes v1 deep queries to the deep index, one hit per message', async () => {
    const search = registerSearch(workerFor({ deep, settings: DEEP_SETTINGS, dbPath }));

    const out = await search({ v: 1, query: 'deep memory', scope: { type: 'global' }, mode: 'deep' }) as any;

    expect(out.ok).toBe(true);
    expect(out.hits[0]).toMatchObject({ sessionId: 's1', seqFrom: 3, seqTo: 3, createdAtFromMs: 30, createdAtToMs: 30 });
    expect(out.hits[0].score).toBeGreaterThan(0);
    expect(out.hits[0].score).toBeLessThanOrEqual(1);
  });

  it('falls back to fts-only deep search when embeddings initialization fails', async () => {
    vi.doMock('@huggingface/transformers', () => {
      throw new Error('missing onnx runtime');
    });
    const settings: MemorySettingsV1 = { ...DEEP_SETTINGS, embeddings: { ...DEEP_SETTINGS.embeddings, mode: 'preset', presetId: 'balanced' } };
    const search = registerSearch(workerFor({ deep, settings, dbPath }));

    const out = await search({ v: 1, query: 'banana-embeddings-qa', scope: { type: 'global' }, mode: 'deep' }) as any;

    expect(out.ok).toBe(true);
    expect(out.hits[0]).toMatchObject({ sessionId: 's1', seqFrom: 4 });
  });

  it('answers v2 with highlighted message hits, session details, coverage and a cursor to the next page', async () => {
    const search = registerSearch(workerFor({ deep, settings: DEEP_SETTINGS, dbPath }));

    const first = MemorySearchResultV2Schema.parse(await search({ v: 2, query: 'openclaw', limit: 2 }));
    expect(first.ok).toBe(true);
    if (!first.ok) return;
    expect(first.hits).toHaveLength(2);
    expect(first.coverage).toEqual(COVERAGE);
    expect(first.nextCursor).not.toBeNull();
    const fromS1 = first.hits.find((hit) => hit.sessionId === 's1');
    expect(fromS1?.session).toEqual({ title: 'Memory plan', agent: 'claude' });
    expect(fromS1?.snippet.some((segment) => segment.match && segment.text === 'Openclaw')).toBe(true);

    const second = MemorySearchResultV2Schema.parse(await search({ v: 2, query: 'openclaw', limit: 2, cursor: first.nextCursor }));
    expect(second.ok).toBe(true);
    if (!second.ok) return;
    expect(second.hits).toHaveLength(1);
    expect(second.nextCursor).toBeNull();
    const all = [...first.hits, ...second.hits].map((hit) => `${hit.sessionId}:${hit.seq}`).sort();
    expect(all).toEqual(['s1:3', 's1:4', 's2:9']);
    expect([...first.hits, ...second.hits].find((hit) => hit.sessionId === 's2')?.session).toEqual({ title: null, agent: null });
  });

  it('answers v2 newest first when the query asks for recent messages', async () => {
    // The newest match is the least relevant one.
    deep.upsertMessages({
      sessionId: 's1',
      messages: [{
        seq: 12, createdAtMs: 120, role: 'assistant', kind: 'assistant_message',
        text: 'A long closing note about relays, daemons, runners and budgets that names openclaw only once among many unrelated words.',
      }],
    });
    const search = registerSearch(workerFor({ deep, settings: DEEP_SETTINGS, dbPath }));

    const first = MemorySearchResultV2Schema.parse(await search({ v: 2, query: 'openclaw', limit: 2, order: 'recent' }));
    if (!first.ok) throw new Error('search failed');
    const second = MemorySearchResultV2Schema.parse(await search({ v: 2, query: 'openclaw', limit: 2, order: 'recent', cursor: first.nextCursor }));
    if (!second.ok) throw new Error('search failed');
    expect(second.nextCursor).toBeNull();
    expect([...first.hits, ...second.hits].map((hit) => `${hit.sessionId}:${hit.seq}`)).toEqual(['s1:12', 's2:9', 's1:4', 's1:3']);
  });

  it('tells v2 callers why the full-text index cannot answer', async () => {
    const disabled = registerSearch(workerFor({ deep: null, settings: { ...DEEP_SETTINGS, enabled: false }, dbPath }));
    expect(await disabled({ v: 2, query: 'openclaw' })).toEqual({
      v: 2, ok: false, errorCode: 'memory_disabled', error: 'Conversation search is turned off on this machine.',
    });

    const hintsOnly = registerSearch(workerFor({ deep: null, settings: { ...DEEP_SETTINGS, indexMode: 'hints' }, dbPath }));
    expect(await hintsOnly({ v: 2, query: 'openclaw' })).toMatchObject({ v: 2, ok: false, errorCode: 'memory_index_missing' });

    const ready = registerSearch(workerFor({ deep, settings: DEEP_SETTINGS, dbPath }));
    expect(await ready({ v: 2, query: '   ' })).toMatchObject({ v: 2, ok: false, errorCode: 'memory_invalid_query' });
    expect(await ready({ v: 2, query: 'openclaw', cursor: 'not-a-cursor' })).toMatchObject({ v: 2, ok: false, errorCode: 'memory_invalid_query' });
  });

  it('switches conversation search for this machine and refuses malformed switches', async () => {
    const handlers = registerHandlers(workerFor({ deep: null, settings: { ...DEEP_SETTINGS, enabled: false }, dbPath }));
    const set = handlers.get(RPC_METHODS.DAEMON_MEMORY_MESSAGE_SEARCH_SET)!;
    const status = handlers.get(RPC_METHODS.DAEMON_MEMORY_MESSAGE_SEARCH_STATUS)!;

    expect(await status({})).toMatchObject({ v: 1, enabled: false, state: 'off' });
    expect(await set({ v: 1, enabled: true })).toMatchObject({ v: 1, enabled: true, state: 'indexing' });
    expect(await set({ enabled: 'yes' })).toEqual({ ok: false, errorCode: 'invalid_parameters', error: 'invalid_parameters' });
  });
});

import { describe, expect, it } from 'vitest';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

import { RPC_METHODS } from '@happier-dev/protocol/rpc';
import { MemoryStatusV1Schema } from '@happier-dev/protocol';

import { openDeepIndexDb } from '@/daemon/memory/deepIndex/deepIndexDb';
import { openSummaryShardIndexDb } from '@/daemon/memory/summaryShardIndexDb';
import { registerMachineMemoryRpcHandlers } from './rpcHandlers.memory';

describe('rpcHandlers.memory (status)', () => {
  it('returns db paths and sizes when available', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'happier-rpc-memory-status-'));
    try {
      const tier1Path = join(dir, 'memory.sqlite');
      const deepPath = join(dir, 'deep.sqlite');
      await writeFile(tier1Path, Buffer.from('hello'), 'utf8');
      await writeFile(deepPath, Buffer.from('worldworld'), 'utf8');

      const handlers = new Map<string, (raw: unknown) => Promise<unknown>>();
      const rpcHandlerManager = {
        registerHandler: (method: string, handler: (params: any) => Promise<any>) => {
          handlers.set(method, handler);
        },
      } as any;

      const memoryWorker = {
        stop: () => {},
        reloadSettings: async () => {},
        ensureUpToDate: async () => {},
        getEmbeddingsDiagnostics: () => ({
          mode: 'preset',
          presetId: 'balanced',
          providerKind: 'local_transformers',
          modelId: 'Xenova/all-MiniLM-L6-v2',
          runtimeState: 'ready',
          usingFallback: false,
        }),
        getSettings: () => ({
          v: 1,
          enabled: true,
          indexMode: 'deep' as const,
          embeddings: { mode: 'preset', presetId: 'balanced', custom: null, blend: { ftsWeight: 0.7, embeddingWeight: 0.3 } },
        }),
        getTier1DbPath: () => tier1Path,
        getDeepDbPath: () => deepPath,
        getDeepIndex: () => null,
      };

      registerMachineMemoryRpcHandlers({
        rpcHandlerManager,
        memoryWorker: memoryWorker as any,
      });

      const handler = handlers.get(RPC_METHODS.DAEMON_MEMORY_STATUS);
      expect(handler).toBeTruthy();
      const out = MemoryStatusV1Schema.parse(await handler!(null));

      expect(out.enabled).toBe(true);
      expect(out.indexMode).toBe('deep');
      expect(out.hintsIndexReady).toBe(true);
      expect(out.deepIndexReady).toBe(true);
      expect(out.activeIndexReady).toBe(true);
      expect(out.embeddingsEnabled).toBe(true);
      expect(out.embeddingsMode).toBe('preset');
      expect(out.embeddingsPresetId).toBe('balanced');
      expect(out.embeddingsProviderKind).toBe('local_transformers');
      expect(out.embeddingsModelId).toBe('Xenova/all-MiniLM-L6-v2');
      expect(out.embeddingsRuntimeState).toBe('ready');
      expect(out.embeddingsUsingFallback).toBe(false);
      expect(out.tier1DbPath).toBe(tier1Path);
      expect(out.deepDbPath).toBe(deepPath);
      expect(out.tier1DbBytes).toBeGreaterThan(0);
      expect(out.deepDbBytes).toBeGreaterThan(0);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  it('populates content, queue, worker, last run, and searchable readiness from memory databases', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'happier-rpc-memory-status-content-'));
    try {
      const tier1Path = join(dir, 'memory.sqlite');
      const deepPath = join(dir, 'deep.sqlite');
      const tier1 = openSummaryShardIndexDb({ dbPath: tier1Path });
      tier1.init();
      tier1.insertSummaryShard({
        sessionId: 'sess-1',
        seqFrom: 1,
        seqTo: 2,
        createdAtFromMs: 1000,
        createdAtToMs: 2000,
        summary: 'OpenClaw searchable memory content',
        keywords: ['openclaw'],
        entities: [],
        decisions: [],
      });
      tier1.recordMemorySessionIndexState({
        sessionId: 'sess-1',
        status: 'indexed',
        coveragePolicyJson: '{"type":"full"}',
        semanticRowsFound: 2,
        semanticRowsIndexedLight: 2,
        lightShardCount: 1,
        updatedAtMs: 3000,
      });
      tier1.recordMemoryWorkerRun({
        runId: 'run-1',
        startedAtMs: 2500,
        finishedAtMs: 3000,
        trigger: 'manual',
        indexMode: 'hints',
        sessionsConsidered: 1,
        sessionsProcessed: 1,
        sessionsIndexed: 1,
        rawRowsFetched: 4,
        semanticRowsFound: 2,
        lightShardsCreated: 1,
      });
      tier1.close();

      const deep = openDeepIndexDb({ dbPath: deepPath, accountId: 'acct-1' });
      deep.upsertMessages({
        sessionId: 'sess-1',
        messages: [{ seq: 2, createdAtMs: 2000, role: 'assistant', kind: 'assistant_message', text: 'OpenClaw deep memory content' }],
      });

      const handlers = new Map<string, (raw: unknown) => Promise<unknown>>();
      const rpcHandlerManager = {
        registerHandler: (method: string, handler: (params: any) => Promise<any>) => {
          handlers.set(method, handler);
        },
      } as any;

      const memoryWorker = {
        stop: () => {},
        reloadSettings: async () => {},
        ensureUpToDate: async () => {},
        getEmbeddingsDiagnostics: () => ({
          mode: 'disabled',
          presetId: null,
          providerKind: null,
          modelId: null,
          runtimeState: 'unavailable',
          usingFallback: false,
        }),
        getSettings: () => ({
          v: 1,
          enabled: true,
          indexMode: 'hints' as const,
          embeddings: { mode: 'disabled', presetId: 'balanced', custom: null, blend: { ftsWeight: 0.7, embeddingWeight: 0.3 } },
        }),
        getTier1DbPath: () => tier1Path,
        getDeepDbPath: () => deepPath,
        getDeepIndex: () => deep,
        getWorkerStatus: () => ({
          state: 'idle',
          lastTickAtMs: 4_000,
          lastInventoryAtMs: 3_500,
          currentSessionId: null,
          currentPhase: null,
        }),
      };

      registerMachineMemoryRpcHandlers({
        rpcHandlerManager,
        memoryWorker: memoryWorker as any,
      });

      const handler = handlers.get(RPC_METHODS.DAEMON_MEMORY_STATUS);
      const out = MemoryStatusV1Schema.parse(await handler!(null));

      expect(out.hintsIndexHasContent).toBe(true);
      expect(out.deepIndexHasContent).toBe(true);
      expect(out.activeIndexSearchable).toBe(true);
      expect(out.indexContent).toMatchObject({
        lightShardCount: 1,
        deepChunkCount: 1,
        searchableSessionCount: 1,
        latestIndexedMessageAtMs: 2000,
      });
      expect(out.queue).toMatchObject({ indexedSessionCount: 1 });
      deep.close();
      expect(out.worker).toMatchObject({ lastTickAtMs: 4_000 });
      expect(out.lastRun).toEqual(expect.objectContaining({
        startedAtMs: 2500,
        sessionsProcessed: 1,
        lightShardsCreated: 1,
      }));
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});

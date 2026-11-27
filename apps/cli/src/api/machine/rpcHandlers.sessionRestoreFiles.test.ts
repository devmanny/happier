import { chmod, mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { RPC_METHODS } from '@happier-dev/protocol/rpc';
import { SPAWN_SESSION_ERROR_CODES } from '@happier-dev/protocol';
import type { Credentials } from '@/persistence';
import { createEnvKeyScope } from '@/testkit/env/envScope';
import { createTempDir, removeTempDir } from '@/testkit/fs/tempDir';

/**
 * `session.restoreFiles` through the daemon machine RPC registration. Boundaries: stored
 * credentials, the server's session/messages HTTP clients and the Claude Agent SDK `query()`.
 * The catalog dispatch and the Claude owner stay real.
 */
const readCredentials = vi.hoisted(() => vi.fn<() => Promise<Credentials | null>>());
const fetchSessionByIdCompat = vi.hoisted(() => vi.fn());
const fetchEncryptedTranscriptPageAfterSeq = vi.hoisted(() => vi.fn());
const sdkQuery = vi.hoisted(() => vi.fn());

vi.mock('ps-list', () => ({ default: vi.fn(async () => []) }));

vi.mock('@/persistence', async (importOriginal) => ({
  ...await importOriginal<typeof import('@/persistence')>(),
  readCredentials,
  readDaemonState: async () => null,
}));

vi.mock('@/configuration', () => ({
  configuration: {
    serverUrl: 'http://example.invalid',
    apiServerUrl: 'http://example.invalid',
    activeServerId: 'cloud',
    activeServerDir: '/tmp/happier-test-active-server',
    happyHomeDir: '/tmp/happier-test-home',
    logsDir: '/tmp',
    daemonStateFile: '/tmp/happier-test-home/daemon.state.json',
    daemonReattachCatchUpConcurrency: 0,
    isDaemonProcess: false,
  },
}));

vi.mock('@/session/transport/http/sessionsHttp', async (importOriginal) => ({
  ...await importOriginal<typeof import('@/session/transport/http/sessionsHttp')>(),
  fetchSessionByIdCompat,
}));

vi.mock('@/api/session/fetchEncryptedTranscriptWindow', async (importOriginal) => ({
  ...await importOriginal<typeof import('@/api/session/fetchEncryptedTranscriptWindow')>(),
  fetchEncryptedTranscriptPageAfterSeq,
}));

vi.mock('@anthropic-ai/claude-agent-sdk', async (importOriginal) => ({
  ...await importOriginal<typeof import('@anthropic-ai/claude-agent-sdk')>(),
  query: sdkQuery,
}));

import { registerMachineRpcHandlers } from './rpcHandlers';

const CLAUDE_SESSION_ID = '0f9e8d7c-aaaa-4bbb-8ccc-dddddddddddd';

function registerRestoreHandler() {
  const registered = new Map<string, (params: unknown) => Promise<unknown>>();
  registerMachineRpcHandlers({
    rpcHandlerManager: {
      registerHandler: (method: string, handler: (params: unknown) => Promise<unknown>) => {
        registered.set(method, handler);
      },
    } as any,
    handlers: {
      spawnSession: vi.fn() as any,
      stopSession: async () => true,
      requestShutdown: () => {},
    },
  });
  const handler = registered.get(RPC_METHODS.SESSION_RESTORE_FILES);
  expect(handler).toBeDefined();
  return handler!;
}

function primeSession(metadata: Record<string, unknown>): void {
  fetchSessionByIdCompat.mockResolvedValue({
    id: 'sess_parent',
    seq: 2,
    createdAt: 1,
    updatedAt: 2,
    active: true,
    activeAt: 2,
    encryptionMode: 'plain',
    metadata: JSON.stringify(metadata),
    metadataVersion: 0,
    agentState: null,
    agentStateVersion: 0,
    dataEncryptionKey: null,
  });
}

describe('session.restoreFiles machine RPC', () => {
  const env = createEnvKeyScope(['HAPPIER_CLAUDE_PATH']);
  let root = '';

  beforeEach(async () => {
    root = await createTempDir('happier-restore-rpc-');
    readCredentials.mockReset();
    fetchSessionByIdCompat.mockReset();
    fetchEncryptedTranscriptPageAfterSeq.mockReset();
    sdkQuery.mockReset();
    readCredentials.mockResolvedValue({
      token: 'token-1',
      encryption: { type: 'legacy', secret: new Uint8Array(32).fill(5) },
    } as Credentials);
  });

  afterEach(async () => {
    env.restore();
    await removeTempDir(root);
  });

  it('rejects params outside the strict contract before loading the session', async () => {
    const handler = registerRestoreHandler();

    const result = await handler({
      v: 1,
      sessionId: 'sess_parent',
      target: { type: 'before_user_message', userMessageSeq: 1 },
      checkpointUuid: 'u-1',
    });

    expect(result).toEqual({ ok: false, errorCode: SPAWN_SESSION_ERROR_CODES.INVALID_REQUEST, errorMessage: 'Invalid params' });
    expect(fetchSessionByIdCompat).not.toHaveBeenCalled();
  });

  it('answers unsupported for an Agent without a file-restore hook', async () => {
    primeSession({ path: root, flavor: 'gemini' });
    const handler = registerRestoreHandler();

    const result = await handler({ v: 1, sessionId: 'sess_parent', target: { type: 'before_user_message', userMessageSeq: 1 } });

    expect(result).toMatchObject({ ok: true, restorable: false, reasonCode: 'unsupported' });
    expect(fetchEncryptedTranscriptPageAfterSeq).not.toHaveBeenCalled();
    expect(sdkQuery).not.toHaveBeenCalled();
  });

  it('dispatches a Claude session to the Claude restore owner', async () => {
    const configDir = join(root, 'claude-config');
    const directory = join(root, 'repo');
    const transcriptPath = join(configDir, 'projects', '-repo', `${CLAUDE_SESSION_ID}.jsonl`);
    const claudeExecutable = join(root, 'claude');
    await mkdir(join(configDir, 'projects', '-repo'), { recursive: true });
    await mkdir(directory, { recursive: true });
    await writeFile(transcriptPath, `${JSON.stringify({
      type: 'user',
      uuid: 'u-hello',
      isSidechain: false,
      cwd: directory,
      message: { role: 'user', content: 'hello there' },
    })}\n`);
    await writeFile(claudeExecutable, '#!/bin/sh\nexit 0\n');
    await chmod(claudeExecutable, 0o755);
    env.patch({ HAPPIER_CLAUDE_PATH: claudeExecutable });
    primeSession({
      path: directory,
      flavor: 'claude',
      claudeSessionId: CLAUDE_SESSION_ID,
      claudeTranscriptPath: transcriptPath,
      nativeAgentEnvironmentV1: { CLAUDE_CONFIG_DIR: configDir },
    });
    fetchEncryptedTranscriptPageAfterSeq.mockImplementation(async (params: { afterSeq: number }) => [
      { seq: 1, createdAt: 1, localId: 'local-1', content: { t: 'plain', v: { role: 'user', content: { type: 'text', text: 'hello there' } } } },
      { seq: 2, createdAt: 2, localId: 'claude-jsonl:main:user:u-hello', content: { t: 'plain', v: { role: 'agent', content: { type: 'output', data: { type: 'progress' } } } } },
    ].filter((row) => row.seq > params.afterSeq));
    const rewindFiles = vi.fn(async () => ({ canRewind: true, filesChanged: [join(directory, 'a.txt')], insertions: 1, deletions: 0 }));
    sdkQuery.mockReturnValue({ rewindFiles, close: vi.fn(), async *[Symbol.asyncIterator]() {} });
    const handler = registerRestoreHandler();

    const result = await handler({
      v: 1,
      sessionId: 'sess_parent',
      target: { type: 'before_user_message', userMessageSeq: 1 },
      dryRun: true,
    });

    expect(result).toEqual({
      ok: true,
      restorable: true,
      restored: false,
      filesChanged: [join(directory, 'a.txt')],
      insertions: 1,
      deletions: 0,
    });
    expect(rewindFiles).toHaveBeenCalledWith('u-hello', { dryRun: true });
  });

  it('answers a failure inside the Agent restore with the contract\'s failure shape', async () => {
    primeSession({
      path: root,
      flavor: 'claude',
      claudeSessionId: CLAUDE_SESSION_ID,
      nativeAgentEnvironmentV1: { CLAUDE_CONFIG_DIR: join(root, 'claude-config') },
    });
    fetchEncryptedTranscriptPageAfterSeq.mockRejectedValue(new Error('Unexpected status from /v1/sessions/:id/messages: 503'));
    const handler = registerRestoreHandler();

    const result = await handler({ v: 1, sessionId: 'sess_parent', target: { type: 'before_user_message', userMessageSeq: 1 } });

    expect(result).toEqual({
      ok: false,
      errorCode: SPAWN_SESSION_ERROR_CODES.UNEXPECTED,
      errorMessage: 'Unexpected status from /v1/sessions/:id/messages: 503',
    });
    expect(sdkQuery).not.toHaveBeenCalled();
  });
});

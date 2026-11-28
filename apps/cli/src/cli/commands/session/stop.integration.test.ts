import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createServer, type Server } from 'node:http';
import { bindApiSessionSocketMock, createApiSessionSocketStub } from '@/testkit/backends/apiSessionSocketHarness';
import { createEnvKeyScope } from '@/testkit/env/envScope';
import { createTempDir, removeTempDir } from '@/testkit/fs/tempDir';
import { captureConsoleJsonOutput } from '@/testkit/logger/captureOutput';

import { deriveBoxPublicKeyFromSeed } from '@happier-dev/protocol';

const { mockIo } = vi.hoisted(() => ({
  mockIo: vi.fn(),
}));
const { stopDaemonSessionMock } = vi.hoisted(() => ({
  stopDaemonSessionMock: vi.fn(),
}));
const { listSessionMarkersMock, removeSessionMarkerMock, isPidSafeHappySessionProcessMock } = vi.hoisted(() => ({
  listSessionMarkersMock: vi.fn(),
  removeSessionMarkerMock: vi.fn(),
  isPidSafeHappySessionProcessMock: vi.fn(),
}));

vi.mock('socket.io-client', () => ({
  io: mockIo,
}));
vi.mock('@/daemon/controlClient', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/daemon/controlClient')>();
  return {
    ...actual,
    stopDaemonSession: stopDaemonSessionMock,
  };
});
vi.mock('@/daemon/sessionRegistry', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/daemon/sessionRegistry')>();
  return {
    ...actual,
    listSessionMarkers: listSessionMarkersMock,
    removeSessionMarker: removeSessionMarkerMock,
  };
});
vi.mock('@/daemon/pidSafety', () => ({
  isPidSafeHappySessionProcess: isPidSafeHappySessionProcessMock,
}));

describe('happier session stop (integration)', () => {
  const envKeys = ['HAPPIER_SERVER_URL', 'HAPPIER_WEBAPP_URL', 'HAPPIER_HOME_DIR'] as const;
  let envScope = createEnvKeyScope(envKeys);
  let server: Server | null = null;
  let happyHomeDir = '';
  let sessionActive = true;
  let sessionStatusFetchCount = 0;
  let sessionStatusShouldFail = false;
  let sessionMetadata = 'metadata_ciphertext';

  beforeEach(async () => {
    happyHomeDir = await createTempDir('happier-cli-session-stop-');
    sessionActive = true;
    sessionStatusFetchCount = 0;
    sessionStatusShouldFail = false;
    sessionMetadata = 'metadata_ciphertext';

    server = createServer((req, res) => {
      const url = new URL(req.url ?? '/', `http://${req.headers.host ?? '127.0.0.1'}`);
      if (req.method === 'GET' && url.pathname.startsWith('/v2/sessions/')) {
        const sessionId = url.pathname.slice('/v2/sessions/'.length).trim();
        sessionStatusFetchCount += 1;
        if (sessionStatusShouldFail) {
          res.statusCode = 503;
          res.setHeader('content-type', 'application/json');
          res.end(JSON.stringify({ error: 'temporary_unavailable' }));
          return;
        }
        res.statusCode = 200;
        res.setHeader('content-type', 'application/json');
        res.end(
          JSON.stringify({
            session: {
              id: sessionId,
              seq: 1,
              createdAt: 1,
              updatedAt: 2,
              active: sessionActive,
              activeAt: sessionActive ? 10 : 0,
              metadata: sessionMetadata,
              metadataVersion: 0,
              agentState: null,
              agentStateVersion: 0,
              pendingCount: 0,
              pendingVersion: 0,
              dataEncryptionKey: null,
              share: null,
            },
          }),
        );
        return;
      }
      res.statusCode = 404;
      res.end();
    });

    await new Promise<void>((resolve) => server!.listen(0, '127.0.0.1', () => resolve()));
    const address = server.address();
    if (!address || typeof address === 'string') throw new Error('Failed to resolve integration server address');

    process.env.HAPPIER_SERVER_URL = `http://127.0.0.1:${address.port}`;
    process.env.HAPPIER_WEBAPP_URL = 'http://127.0.0.1:3000';
    process.env.HAPPIER_HOME_DIR = happyHomeDir;

    const { reloadConfiguration } = await import('@/configuration');
    reloadConfiguration();

    mockIo.mockReset();
    stopDaemonSessionMock.mockReset();
    listSessionMarkersMock.mockReset();
    listSessionMarkersMock.mockResolvedValue([]);
    removeSessionMarkerMock.mockReset();
    removeSessionMarkerMock.mockResolvedValue(undefined);
    isPidSafeHappySessionProcessMock.mockReset();
    isPidSafeHappySessionProcessMock.mockResolvedValue(true);
  });

  afterEach(async () => {
    if (server) {
      await new Promise<void>((resolve, reject) => {
        server!.close((error) => (error ? reject(error) : resolve()));
      });
    }
    server = null;

    if (happyHomeDir) {
      await removeTempDir(happyHomeDir);
      happyHomeDir = '';
    }

    envScope.restore();
    envScope = createEnvKeyScope(envKeys);

    const { reloadConfiguration } = await import('@/configuration');
    reloadConfiguration();
  });

  it('uses the daemon-owned stop path and avoids emitting session-end when the daemon reports success', async () => {
    const sessionId = 'sess_integration_stop_123';
    const emitSpy = vi.fn((...args: any[]) => {
      const cb = args[2];
      sessionActive = false;
      if (typeof cb === 'function') cb();
    });
    stopDaemonSessionMock.mockImplementation(async (requestedSessionId: string) => {
      expect(requestedSessionId).toBe(sessionId);
      sessionActive = false;
      return { status: 'stopped' } as const;
    });

    const socket = createApiSessionSocketStub({
      emit: (event: string, args: unknown[]) => emitSpy(event, ...args),
    });
    bindApiSessionSocketMock(mockIo, socket);

    const { handleSessionCommand } = await import('./index');

    const output = captureConsoleJsonOutput();

    try {
      const machineKeySeed = new Uint8Array(32).fill(8);
      await handleSessionCommand(['stop', sessionId, '--json'], {
        readCredentialsFn: async () => ({
          token: 'token_test',
          encryption: {
            type: 'dataKey',
            publicKey: deriveBoxPublicKeyFromSeed(machineKeySeed),
            machineKey: machineKeySeed,
          },
        }),
      });

      expect(stopDaemonSessionMock).toHaveBeenCalledWith(sessionId);
      expect(emitSpy).not.toHaveBeenCalled();
      expect(sessionStatusFetchCount).toBeGreaterThanOrEqual(2);

      const parsed = output.json();
      expect(parsed.ok).toBe(true);
      expect(parsed.kind).toBe('session_stop');
      expect(parsed.data?.sessionId).toBe(sessionId);
      expect(parsed.data?.stopped).toBe(true);
    } finally {
      output.restore();
    }
  });

  it('reports stopped false when the daemon stop path is unavailable instead of falling back to session-end', async () => {
    const sessionId = 'sess_integration_stop_timeout';
    const emitSpy = vi.fn((...args: any[]) => {
      const cb = args[2];
      if (typeof cb === 'function') cb();
    });
    stopDaemonSessionMock.mockResolvedValue({ status: 'not_found' });

    const socket = createApiSessionSocketStub({
      emit: (event: string, args: unknown[]) => emitSpy(event, ...args),
    });
    bindApiSessionSocketMock(mockIo, socket);

    process.env.HAPPIER_SESSION_STOP_TIMEOUT_MS = '20';
    process.env.HAPPIER_SESSION_STOP_POLL_INTERVAL_MS = '1';

    const { handleSessionCommand } = await import('./index');

    const output = captureConsoleJsonOutput();

    try {
      const machineKeySeed = new Uint8Array(32).fill(8);
      await handleSessionCommand(['stop', sessionId, '--json'], {
        readCredentialsFn: async () => ({
          token: 'token_test',
          encryption: {
            type: 'dataKey',
            publicKey: deriveBoxPublicKeyFromSeed(machineKeySeed),
            machineKey: machineKeySeed,
          },
        }),
      });

      expect(stopDaemonSessionMock).toHaveBeenCalledWith(sessionId);
      expect(emitSpy).not.toHaveBeenCalled();
      expect(sessionStatusFetchCount).toBeGreaterThanOrEqual(1);

      const parsed = output.json();
      expect(parsed.ok).toBe(true);
      expect(parsed.kind).toBe('session_stop');
      expect(parsed.data?.sessionId).toBe(sessionId);
      expect(parsed.data?.stopped).toBe(false);
      expect(parsed.data?.stopOutcome).toEqual({
        status: 'physical_stop_unconfirmed',
        reason: 'local_session_not_found',
      });
    } finally {
      delete process.env.HAPPIER_SESSION_STOP_TIMEOUT_MS;
      delete process.env.HAPPIER_SESSION_STOP_POLL_INTERVAL_MS;
      output.restore();
    }
  });

  it('does not signal a marker-backed runner without committed terminal topology proof', async () => {
    const sessionId = 'sess_integration_stop_marker_fallback';
    const markerPid = 12345;
    const emitSpy = vi.fn((...args: any[]) => {
      const cb = args[2];
      if (typeof cb === 'function') cb();
    });
    stopDaemonSessionMock.mockResolvedValue({ status: 'not_found' });
    listSessionMarkersMock.mockResolvedValue([
      {
        pid: markerPid,
        happySessionId: sessionId,
        happyHomeDir: happyHomeDir,
        createdAt: Date.now(),
        updatedAt: Date.now(),
        startedBy: 'daemon',
        processCommandHash: 'a'.repeat(64),
      },
    ]);

    const processKillSpy = vi.spyOn(process, 'kill').mockImplementation(((pid: number, signal?: NodeJS.Signals | 0) => {
      if (signal === 'SIGTERM' && Math.abs(pid) === markerPid) {
        sessionActive = false;
      }
      return true;
    }) as typeof process.kill);

    const socket = createApiSessionSocketStub({
      emit: (event: string, args: unknown[]) => emitSpy(event, ...args),
    });
    bindApiSessionSocketMock(mockIo, socket);

    process.env.HAPPIER_SESSION_STOP_TIMEOUT_MS = '50';
    process.env.HAPPIER_SESSION_STOP_POLL_INTERVAL_MS = '1';

    const { handleSessionCommand } = await import('./index');

    const output = captureConsoleJsonOutput();

    try {
      const machineKeySeed = new Uint8Array(32).fill(8);
      await handleSessionCommand(['stop', sessionId, '--json'], {
        readCredentialsFn: async () => ({
          token: 'token_test',
          encryption: {
            type: 'dataKey',
            publicKey: deriveBoxPublicKeyFromSeed(machineKeySeed),
            machineKey: machineKeySeed,
          },
        }),
      });

      expect(stopDaemonSessionMock).toHaveBeenCalledWith(sessionId);
      expect(listSessionMarkersMock).toHaveBeenCalledTimes(1);
      expect(isPidSafeHappySessionProcessMock).not.toHaveBeenCalled();
      expect(processKillSpy).not.toHaveBeenCalled();
      expect(removeSessionMarkerMock).not.toHaveBeenCalled();
      expect(emitSpy).not.toHaveBeenCalled();
      expect(sessionStatusFetchCount).toBeGreaterThanOrEqual(1);

      const parsed = output.json();
      expect(parsed.ok).toBe(true);
      expect(parsed.kind).toBe('session_stop');
      expect(parsed.data?.sessionId).toBe(sessionId);
      expect(parsed.data?.stopped).toBe(false);
      expect(parsed.data?.stopOutcome).toEqual({
        status: 'physical_stop_unconfirmed',
        reason: 'missing_topology_proof',
      });
    } finally {
      delete process.env.HAPPIER_SESSION_STOP_TIMEOUT_MS;
      delete process.env.HAPPIER_SESSION_STOP_POLL_INTERVAL_MS;
      processKillSpy.mockRestore();
      output.restore();
    }
  });

  it('reports stopped false when session status polling fails after a successful daemon stop request', async () => {
    const sessionId = 'sess_integration_stop_fetch_failure';
    stopDaemonSessionMock.mockImplementation(async (requestedSessionId: string) => {
      expect(requestedSessionId).toBe(sessionId);
      sessionStatusShouldFail = true;
      return { status: 'stopped' } as const;
    });

    const socket = createApiSessionSocketStub();
    bindApiSessionSocketMock(mockIo, socket);

    process.env.HAPPIER_SESSION_STOP_TIMEOUT_MS = '20';
    process.env.HAPPIER_SESSION_STOP_POLL_INTERVAL_MS = '1';

    const { handleSessionCommand } = await import('./index');

    const output = captureConsoleJsonOutput();

    try {
      const machineKeySeed = new Uint8Array(32).fill(8);
      await handleSessionCommand(['stop', sessionId, '--json'], {
        readCredentialsFn: async () => ({
          token: 'token_test',
          encryption: {
            type: 'dataKey',
            publicKey: deriveBoxPublicKeyFromSeed(machineKeySeed),
            machineKey: machineKeySeed,
          },
        }),
      });

      expect(stopDaemonSessionMock).toHaveBeenCalledWith(sessionId);
      expect(sessionStatusFetchCount).toBeGreaterThanOrEqual(1);

      const parsed = output.json();
      expect(parsed.ok).toBe(true);
      expect(parsed.kind).toBe('session_stop');
      expect(parsed.data?.sessionId).toBe(sessionId);
      expect(parsed.data?.stopped).toBe(false);
      expect(parsed.data?.stopOutcome).toEqual({
        status: 'stopped_projection_unconfirmed',
        reason: 'relay_inactive_not_observed',
      });
    } finally {
      delete process.env.HAPPIER_SESSION_STOP_TIMEOUT_MS;
      delete process.env.HAPPIER_SESSION_STOP_POLL_INTERVAL_MS;
      output.restore();
    }
  });

  describe('--reason idle', () => {
    const secret = new Uint8Array(32).fill(7);
    const readLegacyCredentials = async () => ({
      token: 'token_test',
      encryption: { type: 'legacy' as const, secret },
    });

    async function serveLegacyMetadata(metadata: Record<string, unknown>): Promise<void> {
      const { encodeBase64, encryptLegacy } = await import('@/api/encryption');
      sessionMetadata = encodeBase64(encryptLegacy(metadata, secret), 'base64');
    }

    /** Accepts every metadata write, as the relay does, and keeps what was written. */
    function recordMetadataWrites(): Record<string, unknown>[] {
      const writes: Record<string, unknown>[] = [];
      const socket = createApiSessionSocketStub({
        emit: async (event: string, args: unknown[]) => {
          if (event !== 'update-metadata') return;
          const [data, callback] = args as [{ metadata?: string }, ((value: unknown) => void) | undefined];
          const { decodeBase64, decryptLegacy } = await import('@/api/encryption');
          writes.push(decryptLegacy(decodeBase64(String(data?.metadata ?? ''), 'base64'), secret));
          callback?.({ result: 'success', version: 1, metadata: data?.metadata });
        },
      });
      bindApiSessionSocketMock(mockIo, socket);
      return writes;
    }

    async function runStop(argv: string[]): Promise<any> {
      process.env.HAPPIER_SESSION_STOP_TIMEOUT_MS = '50';
      process.env.HAPPIER_SESSION_STOP_POLL_INTERVAL_MS = '1';
      const { handleSessionCommand } = await import('./index');
      const output = captureConsoleJsonOutput();
      try {
        await handleSessionCommand(argv, { readCredentialsFn: readLegacyCredentials });
        return output.json();
      } finally {
        delete process.env.HAPPIER_SESSION_STOP_TIMEOUT_MS;
        delete process.env.HAPPIER_SESSION_STOP_POLL_INTERVAL_MS;
        output.restore();
      }
    }

    it('records the idle rest on the session after a confirmed stop', async () => {
      const sessionId = 'sess_integration_stop_rest_idle';
      await serveLegacyMetadata({ path: '/tmp/project', host: 'host1', lifecycleState: 'running', lifecycleStateSince: 1_000 });
      stopDaemonSessionMock.mockImplementation(async () => {
        sessionActive = false;
        return { status: 'stopped' } as const;
      });
      const writes = recordMetadataWrites();
      const startedAt = Date.now();

      const parsed = await runStop(['stop', sessionId, '--reason', 'idle', '--json']);

      expect(stopDaemonSessionMock).toHaveBeenCalledWith(sessionId);
      expect(writes).toHaveLength(1);
      expect(writes[0]).toMatchObject({ path: '/tmp/project', host: 'host1', lifecycleState: 'running', lifecycleStateSince: 1_000 });
      const rest = writes[0]?.sessionRestV1 as { v: number; reason: string; at: number };
      expect(rest).toEqual({ v: 1, reason: 'idle', at: expect.any(Number) });
      expect(rest.at).toBeGreaterThanOrEqual(startedAt);
      expect(parsed.ok).toBe(true);
      expect(parsed.data).toEqual({ sessionId, stopped: true, sessionRest: rest });
    });

    it('records the idle rest on a session that was already stopped', async () => {
      const sessionId = 'sess_integration_stop_rest_already';
      sessionActive = false;
      await serveLegacyMetadata({ path: '/tmp/project', lifecycleState: 'running', lifecycleStateSince: 1_000 });
      stopDaemonSessionMock.mockResolvedValue({ status: 'not_found' });
      const writes = recordMetadataWrites();

      const parsed = await runStop(['stop', sessionId, '--reason', 'idle', '--json']);

      expect(writes).toHaveLength(1);
      expect(writes[0]?.sessionRestV1).toEqual({ v: 1, reason: 'idle', at: expect.any(Number) });
      expect(parsed.data).toEqual({
        sessionId,
        stopped: false,
        stopOutcome: { status: 'already_stopped', reason: 'no_runtime_session_inactive' },
        sessionRest: writes[0]?.sessionRestV1,
      });
    });

    it('does not record a rest when the stop is not confirmed', async () => {
      const sessionId = 'sess_integration_stop_rest_unconfirmed';
      await serveLegacyMetadata({ path: '/tmp/project' });
      stopDaemonSessionMock.mockResolvedValue({ status: 'not_found' });
      const writes = recordMetadataWrites();

      const parsed = await runStop(['stop', sessionId, '--reason', 'idle', '--json']);

      expect(writes).toHaveLength(0);
      expect(parsed.data).toEqual({
        sessionId,
        stopped: false,
        stopOutcome: { status: 'physical_stop_unconfirmed', reason: 'local_session_not_found' },
      });
    });

    it('reports a failed rest write without undoing the confirmed stop', async () => {
      const sessionId = 'sess_integration_stop_rest_write_failed';
      await serveLegacyMetadata({ path: '/tmp/project' });
      stopDaemonSessionMock.mockImplementation(async () => {
        sessionActive = false;
        return { status: 'stopped' } as const;
      });
      const socket = createApiSessionSocketStub({
        emit: (event: string, args: unknown[]) => {
          if (event !== 'update-metadata') return;
          const callback = args[1] as ((value: unknown) => void) | undefined;
          callback?.({ result: 'error' });
        },
      });
      bindApiSessionSocketMock(mockIo, socket);

      const parsed = await runStop(['stop', sessionId, '--reason', 'idle', '--json']);

      expect(parsed.ok).toBe(true);
      expect(parsed.data).toEqual({ sessionId, stopped: true, sessionRestError: 'unknown_error' });
    });

    it('refuses a reason outside the closed set before stopping anything', async () => {
      const sessionId = 'sess_integration_stop_rest_bad_reason';
      const writes = recordMetadataWrites();

      const parsed = await runStop(['stop', sessionId, '--reason', 'manual', '--json']);

      expect(parsed.ok).toBe(false);
      expect(parsed.error?.code).toBe('invalid_parameters');
      expect(stopDaemonSessionMock).not.toHaveBeenCalled();
      expect(writes).toHaveLength(0);
    });
  });
});

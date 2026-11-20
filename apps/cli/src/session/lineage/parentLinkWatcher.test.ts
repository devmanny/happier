import { EventEmitter, once } from 'node:events';
import { createServer } from 'node:http';
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { Server } from 'socket.io';
import { z } from 'zod';

import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi, type MockInstance } from 'vitest';

import type { AgentState } from '@/api/types';

import { reloadConfiguration } from '@/configuration';
import { createTempDir, removeTempDir } from '@/testkit/fs/tempDir';
import * as parentNotices from './notifyParentSession';

import { resetParentLinkWatchersForTests, startParentLinkWatcher } from './parentLinkWatcher';

class FakeSession extends EventEmitter {
  constructor(
    public sessionId: string,
    public metadata: Record<string, unknown> | null,
    public requests: NonNullable<AgentState['requests']> = {},
    public thinking = false,
  ) {
    super();
  }

  getMetadataSnapshot() {
    return this.metadata;
  }

  getAgentStateSnapshot(): AgentState {
    return { requests: this.requests };
  }

  getSessionPresenceSnapshot() {
    return { thinking: this.thinking, mode: 'remote' as const };
  }

  setListParent(parentSessionId: string | null, updatedAt: number) {
    this.metadata = { ...(this.metadata ?? {}), listParentV1: { v: 1, updatedAt, parentSessionId } };
    this.emit('metadata-updated');
  }
}

describe('startParentLinkWatcher', () => {
  const captures: Array<{ target: string; message: string }> = [];
  const unexpected: string[] = [];
  let fixtureHome: string;
  let notifyParentLinkChangeBestEffort: MockInstance<typeof parentNotices.notifyParentLinkChangeBestEffort>;
  const sessionIds = ['child-1', 'parent-a', 'parent-b', 'parent-c', 'parent-z'];
  const rows = sessionIds.map(id => ({
    id, seq: 2, createdAt: 1, updatedAt: 2, active: true, activeAt: 1,
    encryptionMode: 'plain', metadata: '{}', metadataVersion: 1,
    agentState: null, agentStateVersion: 0, dataEncryptionKey: null,
  }));
  const noticeBody = z.object({ localId: z.string(),
    content: z.object({ t: z.literal('plain'), v: z.object({
      role: z.literal('user'), content: z.object({ type: z.literal('text'), text: z.string() }),
    }) }) });
  // Real HTTP/Socket.IO boundary; notification, serialization, admission and credentials stay real.
  const server = createServer(async (request, response) => {
    const path = new URL(request.url ?? '/', 'http://localhost').pathname;
    const send = (status: number, value: unknown) => {
      response.writeHead(status, { 'content-type': 'application/json' });
      response.end(JSON.stringify(value));
    };
    if (path === '/v2/account/settings') return send(200, { version: 1, content: { t: 'plain', v: {} } });
    if (path === '/v1/account/encryption/currentness') return send(200, { mode: 'plain', version: 1, signingKeyFingerprint: null, contentKeyFingerprint: null, updatedAt: 1 });
    if (path === '/v2/sessions' || path === '/v2/sessions/archived') return send(200, { sessions: rows, hasNext: false, nextCursor: null });
    const notice = /^\/v2\/sessions\/([^/]+)\/pending$/.exec(path);
    if (request.method === 'POST' && notice) {
      let raw = '';
      for await (const chunk of request) raw += chunk;
      const body = noticeBody.safeParse(JSON.parse(raw));
      if (!body.success) {
        unexpected.push('invalid pending notice');
        return send(400, { error: 'invalid_fixture_admission' });
      }
      captures.push({ target: notice[1]!, message: body.data.content.v.content.text });
      return send(200, { didWrite: true });
    }
    const target = /^\/v2\/sessions\/([^/]+)$/.exec(path)?.[1];
    if (target) {
      const session = rows.find(row => row.id === target);
      return send(session ? 200 : 404, session ? { session } : { error: 'not_found' });
    }
    unexpected.push(`${request.method} ${path}`);
    return send(404, { error: 'unexpected_fixture_route' });
  });
  const io = new Server(server, { path: '/v1/updates' });
  io.on('connection', socket => socket.on('rpc-call', (_request, ack) => {
    ack({ ok: true, result: { ok: true } });
  }));

  // Call-through observation only drains fire-and-forget work. No internal implementation is stubbed.
  const drainNotices = async () => {
    await Promise.all(notifyParentLinkChangeBestEffort.mock.results.map(result => result.type === 'return' ? result.value : undefined));
  };

  beforeAll(async () => {
    fixtureHome = await createTempDir('happier-parent-link-watcher-');
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    const address = server.address();
    if (!address || typeof address === 'string') throw new Error('Expected loopback fixture port');
    const origin = `http://127.0.0.1:${address.port}`;
    vi.stubEnv('HAPPIER_HOME_DIR', fixtureHome);
    vi.stubEnv('HAPPIER_ACTIVE_SERVER_ID', 'fixture');
    vi.stubEnv('HAPPIER_SERVER_URL', origin);
    vi.stubEnv('HAPPIER_LOCAL_SERVER_URL', origin);
    vi.stubEnv('HAPPIER_WEBAPP_URL', origin);
    vi.stubEnv('HAPPIER_SESSION_ID', '');
    reloadConfiguration();
    await mkdir(join(fixtureHome, 'servers', 'fixture'), { recursive: true });
    await writeFile(join(fixtureHome, 'servers', 'fixture', 'access.key'), JSON.stringify({ token: 'synthetic_loopback_only', encryption: null }), { mode: 0o600 });
  });

  beforeEach(() => {
    resetParentLinkWatchersForTests();
    parentNotices.resetParentSessionNoticeStateForTests();
    captures.length = 0;
    unexpected.length = 0;
    notifyParentLinkChangeBestEffort = vi.spyOn(parentNotices, 'notifyParentLinkChangeBestEffort');
    // Existing moves use synthetic timestamps after this initial watcher start.
    vi.spyOn(Date, 'now').mockReturnValue(0);
  });

  afterEach(async () => {
    await drainNotices();
    expect(unexpected).toEqual([]);
    resetParentLinkWatchersForTests();
    vi.restoreAllMocks();
  });

  afterAll(async () => {
    await new Promise<void>(resolve => io.close(() => resolve()));
    vi.unstubAllEnvs();
    await removeTempDir(fixtureHome);
  });

  it('does not announce a move made before this runner started, even if it is seen late', async () => {
    vi.spyOn(Date, 'now').mockReturnValue(1_000);
    const session = new FakeSession('child-1', {
      path: '/repo', host: 'mac',
      spawnedBySessionV1: { v: 1, parentSessionId: 'parent-a', createdAtMs: 1 },
    });
    startParentLinkWatcher(session);
    session.emit('metadata-updated');
    session.setListParent('parent-b', 500);
    await drainNotices();
    expect(captures).toEqual([]);

    session.setListParent('parent-c', 1_500);
    await drainNotices();
    expect(captures.map(notice => notice.target).sort()).toEqual(['child-1', 'parent-b', 'parent-c']);
    expect(captures.find(notice => notice.target === 'parent-b')?.message).toContain('is no longer your direct child');
    expect(captures.find(notice => notice.target === 'parent-c')?.message).toContain('new direct child');
  });

  it('announces a move stamped exactly when the watcher started', async () => {
    vi.spyOn(Date, 'now').mockReturnValue(1_000);
    const session = new FakeSession('child-1', { path: '/repo', host: 'mac' });
    startParentLinkWatcher(session);
    session.setListParent('parent-b', 1_000);
    await drainNotices();
    expect(captures.map(notice => notice.target).sort()).toEqual(['child-1', 'parent-b']);
  });

  it('keeps announcing a changed parent when the metadata has no timestamp', async () => {
    vi.spyOn(Date, 'now').mockReturnValue(1_000);
    const session = new FakeSession('child-1', { path: '/repo', host: 'mac' });
    startParentLinkWatcher(session);
    session.metadata = { ...session.metadata, listParentV1: { v: 1, parentSessionId: 'parent-b' } };
    session.emit('metadata-updated');
    await drainNotices();
    expect(captures.map(notice => notice.target).sort()).toEqual(['child-1', 'parent-b']);
  });

  it('keeps the original start time across a later client swap', async () => {
    vi.spyOn(Date, 'now').mockReturnValue(1_000);
    const metadata = { path: '/repo', host: 'mac', listParentV1: { v: 1, updatedAt: 500, parentSessionId: 'parent-a' } };
    const first = new FakeSession('child-1', metadata);
    startParentLinkWatcher(first);
    vi.spyOn(Date, 'now').mockReturnValue(2_000);
    const second = new FakeSession('child-1', metadata);
    startParentLinkWatcher(second);
    first.setListParent('ignored-after-swap', 2_500);
    second.setListParent('parent-b', 1_500);
    await drainNotices();
    expect(captures.map(notice => notice.target).sort()).toEqual(['child-1', 'parent-a', 'parent-b']);
  });

  it('treats the parent seen at startup as the baseline and does not announce it', () => {
    const session = new FakeSession('child-1', {
      path: '/repo',
      host: 'mac',
      spawnedBySessionV1: { v: 1, parentSessionId: 'parent-a', createdAtMs: 1 },
    });

    startParentLinkWatcher(session);
    session.emit('metadata-updated');

    expect(notifyParentLinkChangeBestEffort).not.toHaveBeenCalled();
  });

  it('does not treat the spawn link arriving after startup as a move', () => {
    // `spawnedBySessionV1` is written by the spawner right after the child process starts,
    // so it can land after the baseline was taken. Only a manual move (`listParentV1`) counts.
    const session = new FakeSession('child-1', { path: '/repo', host: 'mac' });
    startParentLinkWatcher(session);

    session.metadata = { ...session.metadata, spawnedBySessionV1: { v: 1, parentSessionId: 'parent-a', createdAtMs: 1 } };
    session.emit('metadata-updated');

    expect(notifyParentLinkChangeBestEffort).not.toHaveBeenCalled();

    session.setListParent(null, 9);
    expect(notifyParentLinkChangeBestEffort).toHaveBeenCalledWith(expect.objectContaining({
      previousParentSessionId: 'parent-a',
      nextParentSessionId: null,
    }));
  });

  it('ignores a manual move that lands on the parent already in effect', () => {
    const session = new FakeSession('child-1', {
      path: '/repo',
      host: 'mac',
      spawnedBySessionV1: { v: 1, parentSessionId: 'parent-a', createdAtMs: 1 },
    });
    startParentLinkWatcher(session);

    session.setListParent('parent-a', 5);

    expect(notifyParentLinkChangeBestEffort).not.toHaveBeenCalled();
  });

  it('announces a manual move under another session with the child state', () => {
    const session = new FakeSession('child-1', { path: '/repo', host: 'mac' }, { 'req-1': { tool: 'Write', arguments: {}, createdAt: 1 } });
    startParentLinkWatcher(session);

    session.setListParent('parent-b', 500);

    expect(notifyParentLinkChangeBestEffort).toHaveBeenCalledOnce();
    expect(notifyParentLinkChangeBestEffort).toHaveBeenCalledWith({
      session,
      previousParentSessionId: null,
      nextParentSessionId: 'parent-b',
      updatedAt: 500,
      childState: 'blocked',
    });
  });

  it('announces a move back to the top level and a working state', () => {
    const session = new FakeSession('child-1', {
      path: '/repo',
      host: 'mac',
      spawnedBySessionV1: { v: 1, parentSessionId: 'parent-a', createdAtMs: 1 },
    }, {}, true);
    startParentLinkWatcher(session);

    session.setListParent(null, 700);

    expect(notifyParentLinkChangeBestEffort).toHaveBeenCalledWith({
      session,
      previousParentSessionId: 'parent-a',
      nextParentSessionId: null,
      updatedAt: 700,
      childState: 'working',
    });
  });

  it('ignores metadata updates that do not change the effective parent', () => {
    const session = new FakeSession('child-1', { path: '/repo', host: 'mac' });
    startParentLinkWatcher(session);

    session.setListParent('parent-b', 500);
    session.metadata = { ...session.metadata, summary: { text: 'retitled', updatedAt: 1 } };
    session.emit('metadata-updated');

    expect(notifyParentLinkChangeBestEffort).toHaveBeenCalledOnce();
  });

  it('uses the first available metadata as the baseline when none is loaded at startup', () => {
    const session = new FakeSession('child-1', null);
    startParentLinkWatcher(session);

    session.metadata = { path: '/repo', host: 'mac', listParentV1: { v: 1, updatedAt: 1, parentSessionId: 'parent-z' } };
    session.emit('metadata-updated');
    expect(notifyParentLinkChangeBestEffort).not.toHaveBeenCalled();

    session.setListParent(null, 2);
    expect(notifyParentLinkChangeBestEffort).toHaveBeenCalledWith(expect.objectContaining({
      previousParentSessionId: 'parent-z',
      nextParentSessionId: null,
    }));
  });

  it('carries the baseline across a session client swap for the same session id', () => {
    const first = new FakeSession('child-1', { path: '/repo', host: 'mac', listParentV1: { v: 1, updatedAt: 1, parentSessionId: 'parent-a' } });
    startParentLinkWatcher(first);
    const second = new FakeSession('child-1', { path: '/repo', host: 'mac', listParentV1: { v: 1, updatedAt: 1, parentSessionId: 'parent-a' } });
    startParentLinkWatcher(second);

    first.setListParent('ignored-after-swap', 3);
    expect(notifyParentLinkChangeBestEffort).not.toHaveBeenCalled();

    second.setListParent('parent-b', 4);
    expect(notifyParentLinkChangeBestEffort).toHaveBeenCalledWith(expect.objectContaining({
      session: second,
      previousParentSessionId: 'parent-a',
      nextParentSessionId: 'parent-b',
    }));
  });

  it('does not watch offline placeholder sessions', () => {
    const session = new FakeSession('offline-123', { path: '/repo', host: 'mac' });
    startParentLinkWatcher(session);
    session.setListParent('parent-b', 500);
    expect(notifyParentLinkChangeBestEffort).not.toHaveBeenCalled();
  });
});

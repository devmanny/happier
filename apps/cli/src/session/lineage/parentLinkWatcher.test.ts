import { EventEmitter } from 'node:events';

import { beforeEach, describe, expect, it, vi } from 'vitest';

import type { AgentState } from '@/api/types';

const { notifyParentLinkChangeBestEffort } = vi.hoisted(() => ({
  notifyParentLinkChangeBestEffort: vi.fn(async () => undefined),
}));

vi.mock('./notifyParentSession', () => ({
  notifyParentLinkChangeBestEffort,
}));

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
  beforeEach(() => {
    resetParentLinkWatchersForTests();
    notifyParentLinkChangeBestEffort.mockClear();
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

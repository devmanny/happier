import { beforeEach, describe, expect, it, vi } from 'vitest';

import type { Credentials } from '@/persistence';

import {
  notifyParentLinkChangeBestEffort,
  notifyParentSessionBestEffort,
  resetParentSessionNoticeStateForTests,
  type ParentSessionNoticeDeps,
} from './notifyParentSession';

const credentials: Credentials = {
  token: 'token',
  encryption: { type: 'legacy', secret: new Uint8Array([1, 2, 3, 4]) },
};

function createChildSession(parentSessionId: string | null = 'parent-1') {
  return {
    sessionId: 'child-1',
    getMetadataSnapshot: () => ({
      summary: { text: 'Fix flaky test' },
      ...(parentSessionId
        ? { spawnedBySessionV1: { v: 1, parentSessionId, createdAtMs: 1 } }
        : {}),
    }),
  };
}

function createDeps(overrides: Partial<ParentSessionNoticeDeps> = {}) {
  const sendSessionMessage = vi.fn(async () => ({ ok: true as const, sessionId: 'parent-1', localId: 'l', waited: false }));
  const log = vi.fn();
  const deps: ParentSessionNoticeDeps = {
    readCredentials: async () => credentials,
    sendSessionMessage: sendSessionMessage as unknown as ParentSessionNoticeDeps['sendSessionMessage'],
    readSessionMetadata: async () => ({}),
    log,
    ...overrides,
  };
  return { deps, sendSessionMessage, log };
}

describe('notifyParentSessionBestEffort', () => {
  beforeEach(() => {
    resetParentSessionNoticeStateForTests();
  });

  it('does nothing for a session that was not spawned by another session', async () => {
    const { deps, sendSessionMessage } = createDeps();

    await notifyParentSessionBestEffort({
      session: createChildSession(null),
      event: { kind: 'turn_completed', assistantPreviewText: 'done' },
    }, deps);

    expect(sendSessionMessage).not.toHaveBeenCalled();
  });

  it('wakes the parent with an automatic notice that names the child, the event, the excerpt and how to reply', async () => {
    const { deps, sendSessionMessage } = createDeps();

    await notifyParentSessionBestEffort({
      session: createChildSession(),
      event: { kind: 'turn_completed', assistantPreviewText: 'All tests pass now.' },
    }, deps);

    expect(sendSessionMessage).toHaveBeenCalledOnce();
    const [request] = sendSessionMessage.mock.calls[0] as unknown as [Parameters<ParentSessionNoticeDeps['sendSessionMessage']>[0]];
    expect(request).toMatchObject({
      credentials,
      idOrPrefix: 'parent-1',
      wait: false,
      resumeInactiveSession: false,
    });
    expect(request.message).toContain('[Happier automatic notice');
    expect(request.message).toContain('child-1');
    expect(request.message).toContain('Fix flaky test');
    expect(request.message).toContain('finished its turn');
    expect(request.message).toContain('All tests pass now.');
    expect(request.message).toContain('happier session send child-1');
  });

  it('never sends the child its own notice when metadata points at itself', async () => {
    const { deps, sendSessionMessage } = createDeps();

    await notifyParentSessionBestEffort({
      session: { ...createChildSession('child-1') },
      event: { kind: 'turn_completed', assistantPreviewText: null },
    }, deps);

    expect(sendSessionMessage).not.toHaveBeenCalled();
  });

  it('sends a blocked-request notice exactly once per request id across retries', async () => {
    const { deps, sendSessionMessage } = createDeps();
    const event = {
      kind: 'blocked' as const,
      requestKind: 'permission' as const,
      requestId: 'req-1',
      toolName: 'Write',
      toolDetails: 'File: /tmp/out.txt',
    };

    await notifyParentSessionBestEffort({ session: createChildSession(), event }, deps);
    await notifyParentSessionBestEffort({ session: createChildSession(), event }, deps);

    expect(sendSessionMessage).toHaveBeenCalledOnce();
    const [request] = sendSessionMessage.mock.calls[0] as unknown as [{ message: string }];
    expect(request.message).toContain('waiting for permission');
    expect(request.message).toContain('Write');
    expect(request.message).toContain('File: /tmp/out.txt');
  });

  it('collapses a re-emitted ready for the same turn but reports the next turn', async () => {
    const { deps, sendSessionMessage } = createDeps();
    const session = createChildSession();

    await notifyParentSessionBestEffort({ session, event: { kind: 'turn_completed', assistantPreviewText: 'A', turnKey: 't1' } }, deps);
    await notifyParentSessionBestEffort({ session, event: { kind: 'turn_completed', assistantPreviewText: 'A', turnKey: 't1' } }, deps);
    await notifyParentSessionBestEffort({ session, event: { kind: 'turn_completed', assistantPreviewText: 'A', turnKey: 't2' } }, deps);

    expect(sendSessionMessage).toHaveBeenCalledTimes(2);
  });

  it('reports a stop once and stays silent afterwards', async () => {
    const { deps, sendSessionMessage } = createDeps();
    const session = createChildSession();

    await notifyParentSessionBestEffort({ session, event: { kind: 'stopped', reason: 'Killed by user', crashed: false } }, deps);
    await notifyParentSessionBestEffort({ session, event: { kind: 'stopped', reason: 'Killed by user', crashed: false } }, deps);
    await notifyParentSessionBestEffort({ session, event: { kind: 'turn_completed', assistantPreviewText: 'late' } }, deps);

    expect(sendSessionMessage).toHaveBeenCalledOnce();
    const [request] = sendSessionMessage.mock.calls[0] as unknown as [{ message: string }];
    expect(request.message).toContain('stopped');
    expect(request.message).toContain('Killed by user');
  });

  it('logs and swallows a missing or archived parent instead of failing the child', async () => {
    const sendSessionMessage = vi.fn(async () => ({ ok: false as const, code: 'session_archived' as const }));
    const { deps, log } = createDeps({
      sendSessionMessage: sendSessionMessage as unknown as ParentSessionNoticeDeps['sendSessionMessage'],
    });

    await expect(notifyParentSessionBestEffort({
      session: createChildSession(),
      event: { kind: 'turn_failed', message: 'Provider reported an error' },
    }, deps)).resolves.toBeUndefined();

    expect(log).toHaveBeenCalledWith(expect.stringContaining('session_archived'), expect.anything());
  });

  it('logs and swallows transport failures', async () => {
    const sendSessionMessage = vi.fn(async () => { throw new Error('network down'); });
    const { deps, log } = createDeps({
      sendSessionMessage: sendSessionMessage as unknown as ParentSessionNoticeDeps['sendSessionMessage'],
    });

    await expect(notifyParentSessionBestEffort({
      session: createChildSession(),
      event: { kind: 'turn_completed', assistantPreviewText: null },
    }, deps)).resolves.toBeUndefined();

    expect(log).toHaveBeenCalled();
  });

  it('skips silently when no credentials are available', async () => {
    const { deps, sendSessionMessage } = createDeps({ readCredentials: async () => null });

    await notifyParentSessionBestEffort({
      session: createChildSession(),
      event: { kind: 'turn_completed', assistantPreviewText: null },
    }, deps);

    expect(sendSessionMessage).not.toHaveBeenCalled();
  });

  it('refuses to report to a parent whose own effective parent is this session (mutual nesting loop)', async () => {
    // The app can move a session under one of its own children. Both would then report
    // every finished turn to each other forever; the child side breaks that cycle.
    const sendSessionMessage = vi.fn(async () => ({ ok: true as const, sessionId: 'parent-1', localId: 'l', waited: false }));
    const { deps, log } = createDeps({
      sendSessionMessage: sendSessionMessage as unknown as ParentSessionNoticeDeps['sendSessionMessage'],
      readSessionMetadata: async (sessionId) => sessionId === 'parent-1'
        ? { listParentV1: { v: 1, updatedAt: 5, parentSessionId: 'child-1' } }
        : null,
    });

    await notifyParentSessionBestEffort({ session: createChildSession(), event: { kind: 'turn_completed', assistantPreviewText: 'x' } }, deps);

    expect(sendSessionMessage).not.toHaveBeenCalled();
    expect(log).toHaveBeenCalledWith(expect.stringContaining('mutual'), expect.objectContaining({ parentSessionId: 'parent-1' }));
  });

  it('still reports when the parent metadata cannot be read', async () => {
    const { deps, sendSessionMessage } = createDeps({ readSessionMetadata: async () => { throw new Error('offline'); } });

    await notifyParentSessionBestEffort({ session: createChildSession(), event: { kind: 'turn_completed', assistantPreviewText: 'x' } }, deps);

    expect(sendSessionMessage).toHaveBeenCalledOnce();
  });

  it('lets a manual listParentV1 move override the spawning session as the effective parent', async () => {
    const { deps, sendSessionMessage } = createDeps();
    const session = {
      sessionId: 'child-1',
      getMetadataSnapshot: () => ({
        spawnedBySessionV1: { v: 1, parentSessionId: 'parent-1', createdAtMs: 1 },
        listParentV1: { v: 1, updatedAt: 2, parentSessionId: 'parent-2' },
      }),
    };

    await notifyParentSessionBestEffort({ session, event: { kind: 'turn_completed', assistantPreviewText: 'x' } }, deps);

    expect(sendSessionMessage).toHaveBeenCalledOnce();
    expect((sendSessionMessage.mock.calls as unknown as [{ idOrPrefix: string }][])[0]?.[0]).toMatchObject({ idOrPrefix: 'parent-2' });
  });

  it('stops notifying when the session was moved to the top level by hand', async () => {
    const { deps, sendSessionMessage } = createDeps();
    const session = {
      sessionId: 'child-1',
      getMetadataSnapshot: () => ({
        spawnedBySessionV1: { v: 1, parentSessionId: 'parent-1', createdAtMs: 1 },
        listParentV1: { v: 1, updatedAt: 2, parentSessionId: null },
      }),
    };

    await notifyParentSessionBestEffort({ session, event: { kind: 'turn_completed', assistantPreviewText: 'x' } }, deps);

    expect(sendSessionMessage).not.toHaveBeenCalled();
  });

  it('tells every notice recipient to talk only to direct parent and direct children', async () => {
    const { deps, sendSessionMessage } = createDeps();

    await notifyParentSessionBestEffort({ session: createChildSession(), event: { kind: 'turn_completed', assistantPreviewText: 'x' } }, deps);

    const [request] = sendSessionMessage.mock.calls[0] as unknown as [{ message: string }];
    expect(request.message).toMatch(/direct parent/i);
    expect(request.message).toMatch(/direct children/i);
  });

  describe('notifyParentLinkChangeBestEffort', () => {
    const session = {
      sessionId: 'child-1',
      getMetadataSnapshot: () => ({
        path: '/repo/app',
        host: 'mac-mini',
        summary: { text: 'Fix flaky test' },
        listParentV1: { v: 1, updatedAt: 900, parentSessionId: 'parent-new' },
      }),
    };

    it('tells the new parent, the old parent and the child itself, once per transition', async () => {
      const { deps, sendSessionMessage } = createDeps();
      const params = {
        session,
        previousParentSessionId: 'parent-old',
        nextParentSessionId: 'parent-new',
        updatedAt: 900,
        childState: 'ready' as const,
      };

      await notifyParentLinkChangeBestEffort(params, deps);
      await notifyParentLinkChangeBestEffort(params, deps);

      expect(sendSessionMessage).toHaveBeenCalledTimes(3);
      const byTarget = new Map(
        (sendSessionMessage.mock.calls as unknown as [{ idOrPrefix: string; message: string }][])
          .map(([request]) => [request.idOrPrefix, request.message]),
      );
      expect(byTarget.get('parent-new')).toContain('new direct child');
      expect(byTarget.get('parent-new')).toContain('Fix flaky test');
      expect(byTarget.get('parent-new')).toContain('child-1');
      expect(byTarget.get('parent-new')).toContain('/repo/app');
      expect(byTarget.get('parent-new')).toContain('mac-mini');
      expect(byTarget.get('parent-new')).toMatch(/ready/i);
      expect(byTarget.get('parent-old')).toContain('no longer your direct child');
      expect(byTarget.get('parent-old')).toContain('child-1');
      expect(byTarget.get('child-1')).toContain('now a direct child of');
      expect(byTarget.get('child-1')).toContain('parent-new');
      for (const message of byTarget.values()) {
        expect(message).toContain('[Happier automatic notice');
        expect(message).toMatch(/direct parent/i);
      }
    });

    it('tells only the old parent and the child when moved to the top level', async () => {
      const { deps, sendSessionMessage } = createDeps();

      await notifyParentLinkChangeBestEffort({
        session,
        previousParentSessionId: 'parent-old',
        nextParentSessionId: null,
        updatedAt: 901,
        childState: 'working',
      }, deps);

      const targets = (sendSessionMessage.mock.calls as unknown as [{ idOrPrefix: string; message: string }][])
        .map(([request]) => request.idOrPrefix).sort();
      expect(targets).toEqual(['child-1', 'parent-old']);
      const self = (sendSessionMessage.mock.calls as unknown as [{ idOrPrefix: string; message: string }][])
        .find(([request]) => request.idOrPrefix === 'child-1')?.[0].message;
      expect(self).toContain('no longer have a parent');
      expect(self).toContain('top level');
    });

    it('is not silenced by an earlier stop notice and skips a self-parent', async () => {
      const { deps, sendSessionMessage } = createDeps();
      await notifyParentLinkChangeBestEffort({
        session,
        previousParentSessionId: null,
        nextParentSessionId: 'child-1',
        updatedAt: 902,
        childState: 'ready',
      }, deps);
      expect(sendSessionMessage).toHaveBeenCalledOnce();
      expect((sendSessionMessage.mock.calls as unknown as [{ idOrPrefix: string }][])[0]?.[0]).toMatchObject({ idOrPrefix: 'child-1' });
    });
  });
});

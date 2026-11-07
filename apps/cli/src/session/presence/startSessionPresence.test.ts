import { EventEmitter } from 'node:events';

import { afterEach, describe, expect, it } from 'vitest';

import type { Credentials } from '@/persistence';

import type { PresenceKvTransport } from './sessionPresence';
import { getSessionPresence, resetSessionPresenceForTests, startSessionPresence } from './startSessionPresence';

const credentials: Credentials = {
  token: 't',
  encryption: { type: 'dataKey', publicKey: new Uint8Array(32), machineKey: new Uint8Array(32).fill(4) },
};

function createTransport() {
  const writes: Array<{ key: string; value: string | null; version: number }> = [];
  const transport: PresenceKvTransport = {
    list: async () => [],
    mutate: async (mutations) => {
      writes.push(...mutations);
      return { ok: true, results: mutations.map((m) => ({ key: m.key, version: m.version + 1 })) };
    },
  };
  return { writes, transport };
}

function createSession(sessionId: string) {
  const emitter = new EventEmitter();
  return Object.assign(emitter, {
    sessionId,
    getMetadataSnapshot: () => ({ path: '/repo', flavor: 'claude', agentIdentityV1: { v: 1, id: 'a1', name: 'Julián' } }),
  });
}

afterEach(() => resetSessionPresenceForTests());

describe('startSessionPresence', () => {
  it('publishes when a turn starts and removes the record when it ends', async () => {
    const { writes, transport } = createTransport();
    const session = createSession('s1');
    const presence = startSessionPresence(session, credentials, { transport })!;

    session.emit('local-presence', { thinking: true });
    session.emit('local-presence', { thinking: true });
    await presence.flush();
    expect(writes.filter((w) => w.value !== null).length).toBeGreaterThanOrEqual(1);
    expect(presence.isPublished).toBe(true);

    session.emit('local-presence', { thinking: false });
    await presence.flush();
    expect(writes.at(-1)).toMatchObject({ key: 'presence/s1', value: null });
    expect(presence.isPublished).toBe(false);
  });

  it('keeps one presence per session across client swaps and skips offline sessions', () => {
    const { transport } = createTransport();
    const first = startSessionPresence(createSession('s1'), credentials, { transport });
    const second = startSessionPresence(createSession('s1'), credentials, { transport });
    expect(second).toBe(first);
    expect(getSessionPresence('s1')).toBe(first);
    expect(startSessionPresence(createSession('offline-1'), credentials, { transport })).toBeNull();
    expect(startSessionPresence(createSession('s2'), { token: 't', encryption: null }, { transport })).toBeNull();
  });
});

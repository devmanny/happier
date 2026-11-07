import { describe, expect, it } from 'vitest';

import {
  AGENT_PRESENCE_STALE_AFTER_MS,
  openAccountScopedBlobCiphertext,
  sealAccountScopedBlobCiphertext,
  type AgentPresenceV1,
} from '@happier-dev/protocol';

import { SessionPresence, toWhoIsHereResult, type PresenceKvTransport } from './sessionPresence';

const material = { type: 'dataKey', machineKey: new Uint8Array(32).fill(5) } as const;

/** In-memory UserKVStore with the relay's version rules (the HTTP boundary). */
function createKvStore() {
  const rows = new Map<string, { value: string | null; version: number }>();
  const transport: PresenceKvTransport = {
    async list(prefix) {
      return [...rows.entries()]
        .filter(([key, row]) => key.startsWith(prefix) && row.value !== null)
        .map(([key, row]) => ({ key, value: row.value!, version: row.version }));
    },
    async mutate(mutations) {
      const conflicts = mutations.filter((m) => (rows.get(m.key)?.version ?? -1) !== m.version);
      if (conflicts.length > 0) {
        return { ok: false, current: conflicts.map((m) => ({ key: m.key, version: rows.get(m.key)?.version ?? -1 })) };
      }
      const results = mutations.map((m) => {
        const version = m.version + 1;
        rows.set(m.key, { value: m.value, version });
        return { key: m.key, version };
      });
      return { ok: true, results };
    },
  };
  const read = (key: string): AgentPresenceV1 | null => {
    const value = rows.get(key)?.value;
    if (!value) return null;
    return (openAccountScopedBlobCiphertext({ kind: 'agent_presence', material, ciphertext: value })?.value ?? null) as AgentPresenceV1 | null;
  };
  const put = (record: AgentPresenceV1) => {
    const value = sealAccountScopedBlobCiphertext({
      kind: 'agent_presence', material, payload: record, randomBytes: (n) => new Uint8Array(n).fill(2),
    });
    rows.set(`presence/${record.sessionId}`, { value, version: (rows.get(`presence/${record.sessionId}`)?.version ?? -1) + 1 });
  };
  return { rows, transport, read, put };
}

function otherThread(now: number): AgentPresenceV1 {
  return {
    v: 1,
    sessionId: 'mateo-thread',
    agent: { id: 'a-mateo', name: 'Mateo', emoji: '🤖' },
    providerId: 'codex',
    machineId: 'm1',
    host: 'Mac mini',
    directory: '/repo',
    task: 'Login app móvil',
    files: [{ path: '/repo/Composer.swift', since: now - 4 * 60_000 }],
    resources: [{ name: 'build-ios', since: now - 60_000 }],
    updatedAt: now - 10_000,
  };
}

function createPresence(store: ReturnType<typeof createKvStore>, clock: { now: number }) {
  return new SessionPresence({
    sessionId: 'julian-thread',
    transport: store.transport,
    material,
    now: () => clock.now,
    describeSelf: () => ({
      agent: { id: 'a-julian', name: 'Julián', emoji: '🤖' },
      providerId: 'claude',
      machineId: 'm1',
      host: 'Mac mini',
      directory: '/repo',
      task: 'Agentes etapa 1',
    }),
  });
}

describe('SessionPresence', () => {
  it('publishes while a turn runs, keeps the files it edits, and lets go when the turn ends', async () => {
    const store = createKvStore();
    const clock = { now: 1_000_000 };
    const presence = createPresence(store, clock);

    await presence.setWorking(true);
    expect(store.read('presence/julian-thread')).toMatchObject({ agent: { name: 'Julián' }, directory: '/repo', files: [] });

    expect(await presence.beforeFileEdit('/repo/README.md')).toBeNull();
    expect(store.read('presence/julian-thread')?.files.map((f) => f.path)).toEqual(['/repo/README.md']);

    await presence.setWorking(false);
    expect(store.rows.get('presence/julian-thread')?.value).toBeNull();
  });

  it('warns before editing a file another live thread holds, without blocking it', async () => {
    const store = createKvStore();
    const clock = { now: 1_000_000 };
    store.put(otherThread(clock.now));
    const presence = createPresence(store, clock);

    const warning = await presence.beforeFileEdit('/repo/Composer.swift');
    expect(warning).toContain('Mateo 🤖');
    expect(warning).toContain('Login app móvil');
    expect(warning).toContain('4 min');
    // Advisory only: the edit is still recorded as ours too.
    expect(store.read('presence/julian-thread')?.files.map((f) => f.path)).toEqual(['/repo/Composer.swift']);
  });

  it('ignores threads that stopped signalling', async () => {
    const store = createKvStore();
    const clock = { now: 1_000_000 };
    store.put({ ...otherThread(clock.now), updatedAt: clock.now - AGENT_PRESENCE_STALE_AFTER_MS - 1 });
    const presence = createPresence(store, clock);

    expect(await presence.beforeFileEdit('/repo/Composer.swift')).toBeNull();
    expect(await presence.whoIsHere()).toMatchObject({ others: [] });
  });

  it('declares shared resources and reports who else uses them', async () => {
    const store = createKvStore();
    const clock = { now: 1_000_000 };
    store.put(otherThread(clock.now));
    const presence = createPresence(store, clock);

    const report = await presence.whoIsHere({ resources: ['build-ios'] });
    expect(report.conflicts.map((line) => line.includes('build-ios'))).toEqual([true]);
    expect(report.others.map((o) => o.sessionId)).toEqual(['mateo-thread']);
    expect(store.read('presence/julian-thread')?.resources.map((r) => r.name)).toEqual(['build-ios']);
    expect(toWhoIsHereResult(report, clock.now).others[0]).toMatchObject({
      agent: 'Mateo 🤖',
      task: 'Login app móvil',
      files: [{ path: '/repo/Composer.swift', since: '4 min ago' }],
      lastSignal: '10s ago',
    });
  });

  it('recovers when its own record changed under it', async () => {
    const store = createKvStore();
    const clock = { now: 1_000_000 };
    const presence = createPresence(store, clock);
    await presence.setWorking(true);
    // Another writer (e.g. a previous runner of the same session) bumped the version.
    store.rows.set('presence/julian-thread', { value: null, version: 7 });

    await presence.beforeFileEdit('/repo/a.ts');
    expect(store.rows.get('presence/julian-thread')?.version).toBe(8);
    expect(store.read('presence/julian-thread')?.files.map((f) => f.path)).toEqual(['/repo/a.ts']);
  });
});

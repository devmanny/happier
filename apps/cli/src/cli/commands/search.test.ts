import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { mkdir, stat, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import type { MessageSearchSetRequestV1, MessageSearchStatusV1 } from '@happier-dev/protocol';

import { applyEnvValues, restoreEnvValues, snapshotEnvValues } from '@/testkit/env/envSnapshot';
import { createTempDir, removeTempDir } from '@/testkit/fs/tempDir';

const OFF: MessageSearchStatusV1 = { v: 1, enabled: false, state: 'off', coverage: null, indexBytes: null };

describe('happier search', () => {
  const envBackup = snapshotEnvValues(['HAPPIER_HOME_DIR', 'HAPPIER_SERVER_URL', 'HAPPIER_WEBAPP_URL']);
  let homeDir: string | undefined;

  beforeEach(async () => {
    homeDir = await createTempDir('happier-search-command-');
    applyEnvValues({ HAPPIER_HOME_DIR: homeDir, HAPPIER_SERVER_URL: 'https://api.example.test', HAPPIER_WEBAPP_URL: 'https://app.example.test' });
    vi.resetModules();
  });

  afterEach(async () => {
    restoreEnvValues(envBackup);
    vi.resetModules();
    if (homeDir) await removeTempDir(homeDir);
  });

  // The running daemon is a separate process reached over its local control port: faked here.
  function daemon(status: MessageSearchStatusV1 | null) {
    const sets: MessageSearchSetRequestV1[] = [];
    return {
      sets,
      deps: {
        daemonStatus: async () => status,
        daemonSet: async (request: MessageSearchSetRequestV1) => {
          sets.push(request);
          return status ? { ...status, enabled: request.enabled, state: request.enabled ? 'indexing' as const : 'off' as const } : null;
        },
        confirm: async () => true,
      },
    };
  }

  it('turns search on in the machine settings when no daemon is running, for its next start', async () => {
    const { runSearchCommand } = await import('./search');
    const { readMemorySettingsFromDisk } = await import('@/settings/memorySettings');
    const lines: string[] = [];

    const code = await runSearchCommand(['enable'], { ...daemon(null).deps, print: (line) => lines.push(line) });

    expect(code).toBe(0);
    expect(await readMemorySettingsFromDisk()).toMatchObject({ enabled: true, indexMode: 'deep', backfillPolicy: 'all_history' });
    expect(lines.join('\n')).toMatch(/daemon starts/i);
  });

  it('switches a running daemon through it, and reports its progress', async () => {
    const { runSearchCommand } = await import('./search');
    const running = daemon({
      v: 1, enabled: true, state: 'indexing', indexBytes: 5 * 1024 * 1024,
      coverage: { messageCount: 900, sessionCount: 10, knownSessionCount: 40, pendingSessionCount: 30, backfillComplete: false },
    });
    const lines: string[] = [];

    expect(await runSearchCommand(['enable'], { ...running.deps, print: (line) => lines.push(line) })).toBe(0);
    expect(running.sets).toEqual([{ v: 1, enabled: true, deleteIndex: false }]);

    lines.length = 0;
    expect(await runSearchCommand(['status', '--json'], { ...running.deps, print: (line) => lines.push(line) })).toBe(0);
    expect(JSON.parse(lines.join('\n'))).toMatchObject({ enabled: true, state: 'indexing', progress: 0.25, daemon: 'running' });
  });

  it('keeps the index when turned off unless deleting it is confirmed', async () => {
    const { runSearchCommand } = await import('./search');
    const { configuration } = await import('@/configuration');
    const { writeMemorySettingsToDisk, readMemorySettingsFromDisk } = await import('@/settings/memorySettings');
    await writeMemorySettingsToDisk({ v: 1, enabled: true, indexMode: 'deep' });
    const memoryDir = join(configuration.activeServerDir, 'memory');
    await mkdir(memoryDir, { recursive: true });
    await writeFile(join(memoryDir, 'deep.sqlite'), 'index');
    const lines: string[] = [];
    const print = (line: string) => lines.push(line);

    expect(await runSearchCommand(['disable'], { ...daemon(null).deps, print })).toBe(0);
    expect((await readMemorySettingsFromDisk()).enabled).toBe(false);
    expect((await stat(join(memoryDir, 'deep.sqlite'))).isFile()).toBe(true);
    expect(lines.join('\n')).toMatch(/--delete-index/);

    const declined = { ...daemon(null).deps, confirm: async () => false, print };
    expect(await runSearchCommand(['disable', '--delete-index'], declined)).toBe(1);
    expect((await stat(join(memoryDir, 'deep.sqlite'))).isFile()).toBe(true);

    expect(await runSearchCommand(['disable', '--delete-index'], { ...daemon(null).deps, print })).toBe(0);
    await expect(stat(memoryDir)).rejects.toBeTruthy();
  });

  it('deletes through the running daemon so its open index is closed first', async () => {
    const { runSearchCommand } = await import('./search');
    const running = daemon(OFF);
    expect(await runSearchCommand(['disable', '--delete-index', '--yes'], { ...running.deps, print: () => {} })).toBe(0);
    expect(running.sets).toEqual([{ v: 1, enabled: false, deleteIndex: true }]);
  });

  it('rejects an unknown subcommand', async () => {
    const { runSearchCommand } = await import('./search');
    const lines: string[] = [];
    expect(await runSearchCommand(['start'], { ...daemon(null).deps, print: (line) => lines.push(line) })).toBe(1);
    expect(lines.join('\n')).toMatch(/enable\|disable\|status/);
  });
});

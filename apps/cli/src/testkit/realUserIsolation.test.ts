import { describe, expect, it } from 'vitest';
import { spawnSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import { realUserHomeDir } from './realUserIsolation';

// On 11 nov 2026 a unit test that outlived its timeout resolved the real user's daemon service
// (its env override already restored) and wrote `[unit]` over the real LaunchAgent plist. Every
// CLI test process starts isolated from the real user (`vitestSetup.ts`).
describe('CLI unit tests are isolated from the real user', () => {
  const realHome = realUserHomeDir();

  it('resolve the daemon service files under a temporary home by default', async () => {
    const { resolveDaemonServiceCliRuntimeFromEnv, resolveDaemonServicePaths } = await import('@/daemon/service/cli');

    const runtime = resolveDaemonServiceCliRuntimeFromEnv({ processEnv: process.env });

    expect(runtime.userHomeDir).not.toBe(realHome);
    expect(resolveDaemonServicePaths(runtime).installedPath.startsWith(join(realHome, ''))).toBe(false);
  });

  it('fail any write into the real user\'s service and Happier directories', async () => {
    // Probes under directories that don't exist: without the guard they fail with ENOENT, never write.
    const probe = `happier-isolation-probe-${process.pid}`;
    expect(() => writeFileSync(join(realHome, 'Library', 'LaunchAgents', probe, 'x.plist'), '[unit]')).toThrow(/real user/);
    expect(() => writeFileSync(join(realHome, '.config', 'systemd', 'user', probe, 'x.service'), '[unit]')).toThrow(/real user/);
    await expect(writeFile(join(realHome, '.happier', probe, 'daemon.state.json'), '{}')).rejects.toThrow(/real user/);
  });

  it.skipIf(process.platform === 'win32')('keep launchctl and systemctl away from the real service manager', () => {
    for (const command of ['launchctl', 'systemctl']) {
      const result = spawnSync(command, ['list'], { encoding: 'utf8' });
      expect(result.status, command).not.toBe(0);
      expect(result.stderr, command).toMatch(/blocked in Happier CLI tests/);
    }
  });
});

import { existsSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

import { withTempDir } from '@/testkit/fs/tempDir';

import {
  installDarwinDaemonLauncherIfMissing,
  resolveDarwinDaemonLauncherInstall,
  splitDarwinDaemonLauncher,
} from './darwinDaemonLauncher';

describe('darwin daemon launcher', () => {
  it('starts the service through one launcher path per Happier home, installed from the payload only while that path is free', async () => {
    await withTempDir('happier-darwin-launcher-', async (dir) => {
      const happierHomeDir = join(dir, '.happier');
      const payloadLauncher = join(dir, 'payload', 'tools', 'unpacked', 'happier-daemon-launcher');
      const stablePath = join(happierHomeDir, 'bin', 'happier-daemon-launcher');

      expect(resolveDarwinDaemonLauncherInstall({ happierHomeDir, payloadLauncherPaths: [payloadLauncher] })).toBeNull();

      await mkdir(join(dir, 'payload', 'tools', 'unpacked'), { recursive: true });
      writeFileSync(payloadLauncher, 'launcher v1');
      expect(resolveDarwinDaemonLauncherInstall({ happierHomeDir, payloadLauncherPaths: [payloadLauncher] }))
        .toEqual({ path: stablePath, sourcePath: payloadLauncher });

      await mkdir(join(happierHomeDir, 'bin'), { recursive: true });
      writeFileSync(stablePath, 'granted launcher');
      // Installed: the definition keeps starting it and nothing is copied over it.
      expect(resolveDarwinDaemonLauncherInstall({ happierHomeDir, payloadLauncherPaths: [payloadLauncher] }))
        .toEqual({ path: stablePath, sourcePath: null });
      expect(resolveDarwinDaemonLauncherInstall({ happierHomeDir, payloadLauncherPaths: [] }))
        .toEqual({ path: stablePath, sourcePath: null });
    });
  });

  it('installs a missing launcher as an executable and never replaces an installed one', async () => {
    await withTempDir('happier-darwin-launcher-install-', async (dir) => {
      const sourcePath = join(dir, 'payload-launcher');
      const path = join(dir, 'home', 'bin', 'happier-daemon-launcher');
      writeFileSync(sourcePath, 'launcher from this payload');

      await installDarwinDaemonLauncherIfMissing({ path, sourcePath });
      expect(readFileSync(path, 'utf8')).toBe('launcher from this payload');
      expect(statSync(path).mode & 0o777).toBe(0o755);

      // A later CLI update ships its own copy; the installed launcher keeps its bytes (its path and
      // signature are what macOS privacy permissions were granted to).
      writeFileSync(sourcePath, 'launcher from a newer payload');
      await installDarwinDaemonLauncherIfMissing({ path, sourcePath });
      expect(readFileSync(path, 'utf8')).toBe('launcher from this payload');
      expect(existsSync(`${path}.${process.pid}.tmp`)).toBe(false);
    });
  });

  it('separates the launcher from the command it starts, and leaves other definitions whole', () => {
    expect(splitDarwinDaemonLauncher([
      '/Users/me/.happier/bin/happier-daemon-launcher',
      '/Users/me/.happier/bin/happier',
      'daemon',
      'start-sync',
    ])).toEqual({
      launcher: '/Users/me/.happier/bin/happier-daemon-launcher',
      command: ['/Users/me/.happier/bin/happier', 'daemon', 'start-sync'],
    });
    expect(splitDarwinDaemonLauncher(['/Users/me/.happier/bin/happier', 'daemon', 'start-sync'])).toEqual({
      launcher: null,
      command: ['/Users/me/.happier/bin/happier', 'daemon', 'start-sync'],
    });
  });
});

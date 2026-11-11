import fs from 'node:fs';
import { syncBuiltinESMExports } from 'node:module';
import os from 'node:os';
import { join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * Keeps a CLI test process away from the real user's machine state. The daemon service resolves
 * the user's home from the account database (`os.userInfo()`), not `HOME`, so a test without a
 * service-home override (or one whose override was restored while it still ran, after a timeout)
 * targets the real LaunchAgent / systemd unit. On 11 nov 2026 that overwrote the real
 * `com.happier.cli.daemon.default.plist` with a `[unit]` fixture.
 *
 * - `os.userInfo().homedir` is a per-process temporary directory (it outlives env restores).
 * - Writes into the real user's service directories and real Happier home throw.
 * - `launchctl` and `systemctl` on PATH are stubs that refuse to run.
 */
let realHomeDir: string | null = null;

/** The real user's home, as it was before the process was isolated. */
export function realUserHomeDir(): string {
  return realHomeDir ?? os.userInfo().homedir;
}

export function isolateTestProcessFromRealUser(): void {
  const realHome = realUserHomeDir();
  realHomeDir = realHome;
  const scratch = join(os.tmpdir(), `happier-dev-test-user-${process.pid}`);

  const isolatedHome = join(scratch, 'home');
  fs.mkdirSync(isolatedHome, { recursive: true });
  const userInfo = os.userInfo;
  (os as { userInfo: typeof os.userInfo }).userInfo = ((options?: { encoding: BufferEncoding }) =>
    ({ ...userInfo(options), homedir: isolatedHome })) as typeof os.userInfo;

  guardWritesUnder([
    join(realHome, 'Library', 'LaunchAgents'),
    join(realHome, '.config', 'systemd', 'user'),
    join(realHome, '.happier'),
  ]);

  if (process.platform !== 'win32') {
    const bin = join(scratch, 'bin');
    fs.mkdirSync(bin, { recursive: true });
    for (const command of ['launchctl', 'systemctl']) {
      const stub = join(bin, command);
      fs.writeFileSync(stub, `#!/bin/sh\necho "${command} is blocked in Happier CLI tests (it would reach the real service manager)" >&2\nexit 97\n`);
      fs.chmodSync(stub, 0o755);
    }
    process.env.PATH = `${bin}:${process.env.PATH ?? ''}`;
  }
  syncBuiltinESMExports();
}

function toPath(target: unknown): string | null {
  if (typeof target === 'string') return resolve(target);
  if (target instanceof URL) return target.protocol === 'file:' ? resolve(fileURLToPath(target)) : null;
  if (Buffer.isBuffer(target)) return resolve(target.toString());
  return null;
}

function guardWritesUnder(protectedDirs: readonly string[]): void {
  const roots = protectedDirs.map((dir) => resolve(dir));
  const assertAllowed = (target: unknown) => {
    const path = toPath(target);
    if (path && roots.some((root) => path === root || path.startsWith(root + sep))) {
      throw new Error(`A CLI test tried to write the real user's ${path}; use a temporary home (HAPPIER_DAEMON_SERVICE_USER_HOME_DIR, HAPPIER_HOME_DIR).`);
    }
  };

  // Each wrapped call checks every path argument it writes (rename/copy/link: both ends).
  // Promise APIs reject instead of throwing, like the calls they stand in for.
  const wrap = <T extends object>(owner: T, names: readonly string[], pathArgs: number, rejects = false) => {
    for (const name of names) {
      const original = (owner as Record<string, unknown>)[name];
      if (typeof original !== 'function') continue;
      (owner as Record<string, unknown>)[name] = function guarded(this: unknown, ...args: unknown[]) {
        try {
          for (let i = 0; i < pathArgs; i += 1) assertAllowed(args[i]);
        } catch (error) {
          if (rejects) return Promise.reject(error);
          throw error;
        }
        return (original as (...callArgs: unknown[]) => unknown).apply(this, args);
      };
    }
  };
  const single = ['writeFile', 'appendFile', 'mkdir', 'rm', 'rmdir', 'unlink', 'truncate', 'chmod', 'utimes', 'mkdtemp'];
  const pair = ['rename', 'copyFile', 'cp', 'symlink', 'link'];
  wrap(fs, [...single, ...single.map((name) => `${name}Sync`), 'createWriteStream'], 1);
  wrap(fs, [...pair, ...pair.map((name) => `${name}Sync`)], 2);
  wrap(fs.promises, single, 1, true);
  wrap(fs.promises, pair, 2, true);
}

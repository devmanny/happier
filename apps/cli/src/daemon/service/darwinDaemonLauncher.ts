import { existsSync } from 'node:fs';
import { chmod, copyFile, link, mkdir, rm } from 'node:fs/promises';
import { basename, dirname, join } from 'node:path';

import { resolveCliRuntimeAssetPath } from '@/runtime/assets/resolveCliRuntimeAssetPath';

/**
 * The program the macOS background service starts (source: `apps/cli/tools/sources/happier-daemon-launcher`).
 *
 * macOS attributes the privacy permissions (Accessibility, Screen Recording, Full Disk Access, …)
 * requested anywhere in a launchd job's process tree to the file launchd spawned for the job, by
 * real path and code signature; a later `exec` does not change it. The managed shim resolves into
 * `versions/<id>/`, so the service was a new privacy client after every CLI update and macOS asked
 * for every permission again. The service therefore starts this launcher, which only `exec`s the CLI
 * command the definition would otherwise run: same process, same pid, same daemon.
 *
 * Its path and signature are the identity the user grants, so it lives outside every versioned
 * payload, is installed once from the CLI payload when missing, and is never replaced — neither by
 * CLI updates nor by a build signed differently. A different launcher contract ships under a new
 * file name.
 */
export const DARWIN_DAEMON_LAUNCHER_NAME = 'happier-daemon-launcher';

export type DarwinDaemonLauncherInstall = Readonly<{
  /** The stable launcher path the service definition starts. */
  path: string;
  /** The payload copy to install from; `null` when `path` is installed and is kept as it is. */
  sourcePath: string | null;
}>;

export function resolveDarwinDaemonLauncherPath(happierHomeDir: string): string {
  return join(happierHomeDir, 'bin', DARWIN_DAEMON_LAUNCHER_NAME);
}

function resolvePayloadDarwinDaemonLauncherPaths(): string[] {
  // Same layouts as the bundled zellij: an installed payload, then a repository checkout.
  return [
    resolveCliRuntimeAssetPath('tools', 'unpacked', DARWIN_DAEMON_LAUNCHER_NAME),
    resolveCliRuntimeAssetPath('apps', 'cli', 'tools', 'unpacked', DARWIN_DAEMON_LAUNCHER_NAME),
  ];
}

/**
 * The launcher a darwin service definition should start, or `null` when it is neither installed nor
 * shipped by the running CLI (the definition then runs the CLI directly, as before the launcher).
 */
export function resolveDarwinDaemonLauncherInstall(params: Readonly<{
  happierHomeDir: string;
  payloadLauncherPaths?: readonly string[];
}>): DarwinDaemonLauncherInstall | null {
  const path = resolveDarwinDaemonLauncherPath(params.happierHomeDir);
  if (existsSync(path)) {
    return { path, sourcePath: null };
  }
  const payloadLauncherPaths = params.payloadLauncherPaths ?? resolvePayloadDarwinDaemonLauncherPaths();
  const sourcePath = payloadLauncherPaths.find((candidate) => existsSync(candidate)) ?? null;
  return sourcePath ? { path, sourcePath } : null;
}

/**
 * The launcher every service definition built for this platform and Happier home starts — the one
 * decision each expected-definition builder (install, status, start/restart refresh) shares, so no
 * builder writes or expects a definition without it. Only darwin has one.
 */
export function resolveDaemonServiceDarwinLauncher(params: Readonly<{
  platform: string;
  happierHomeDir: string;
}>): DarwinDaemonLauncherInstall | null {
  return params.platform === 'darwin' ? resolveDarwinDaemonLauncherInstall({ happierHomeDir: params.happierHomeDir }) : null;
}

/**
 * Installs the launcher while its path is free. The final step is a hard link, which fails instead
 * of replacing a launcher another install placed first, so an installed launcher keeps its bytes.
 */
export async function installDarwinDaemonLauncherIfMissing(install: Readonly<{
  path: string;
  sourcePath: string;
}>): Promise<void> {
  if (existsSync(install.path)) return;
  await mkdir(dirname(install.path), { recursive: true });
  const temporaryPath = `${install.path}.${process.pid}.tmp`;
  try {
    await copyFile(install.sourcePath, temporaryPath);
    await chmod(temporaryPath, 0o755);
    await link(temporaryPath, install.path).catch((error: unknown) => {
      if ((error as NodeJS.ErrnoException | null)?.code !== 'EEXIST') throw error;
    });
  } finally {
    await rm(temporaryPath, { force: true });
  }
}

/** A darwin definition's program arguments split into the launcher, when present, and the command it starts. */
export function splitDarwinDaemonLauncher(args: readonly string[]): Readonly<{
  launcher: string | null;
  command: readonly string[];
}> {
  const first = args[0];
  if (first !== undefined && basename(first) === DARWIN_DAEMON_LAUNCHER_NAME) {
    return { launcher: first, command: args.slice(1) };
  }
  return { launcher: null, command: args };
}

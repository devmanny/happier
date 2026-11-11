import { describe, expect, it } from 'vitest';

import { planDaemonServiceInstall } from './plan';

/**
 * macOS attributes the privacy permissions of a launchd job's whole process tree to the file the
 * job spawns. The darwin definition therefore starts the daemon through the stable launcher, which
 * execs the CLI command the definition would otherwise run directly.
 */

const DARWIN_BASE = {
  platform: 'darwin',
  channel: 'publicdev',
  targetMode: 'default-following',
  instanceId: 'cloud',
  uid: 501,
  userHomeDir: '/Users/test',
  happierHomeDir: '/Users/test/.happier',
  serverUrl: 'https://api.happier.dev',
  webappUrl: 'https://app.happier.dev',
  publicServerUrl: 'https://api.happier.dev',
  nodePath: '/Users/test/.happier/bin/happier',
  entryPath: '',
} as const;

const LAUNCHER = '/Users/test/.happier/bin/happier-daemon-launcher';

function programArguments(xml: string): string[] {
  const array = /<key>ProgramArguments<\/key>\s*<array>([\s\S]*?)<\/array>/u.exec(xml)?.[1] ?? '';
  return [...array.matchAll(/<string>([\s\S]*?)<\/string>/gu)].map((match) => String(match[1]));
}

describe('planDaemonServiceInstall darwin launcher', () => {
  it('starts the daemon command through the launcher and installs the launcher only when the payload copy is needed', () => {
    const installing = planDaemonServiceInstall({
      ...DARWIN_BASE,
      darwinLauncher: { path: LAUNCHER, sourcePath: '/payload/tools/unpacked/happier-daemon-launcher' },
    });
    const definition = installing.files[0]?.content ?? '';
    expect(programArguments(definition)).toEqual([
      LAUNCHER,
      '/Users/test/.happier/bin/happier',
      'daemon',
      'start-sync',
      '--takeover',
    ]);
    expect(installing.darwinLauncherInstall).toEqual({
      path: LAUNCHER,
      sourcePath: '/payload/tools/unpacked/happier-daemon-launcher',
    });

    const alreadyInstalled = planDaemonServiceInstall({
      ...DARWIN_BASE,
      darwinLauncher: { path: LAUNCHER, sourcePath: null },
    });
    expect(programArguments(alreadyInstalled.files[0]?.content ?? '')[0]).toBe(LAUNCHER);
    expect(alreadyInstalled.darwinLauncherInstall).toBeUndefined();
  });

  it('keeps the direct command when no launcher is available', () => {
    const plan = planDaemonServiceInstall({ ...DARWIN_BASE, darwinLauncher: null });
    expect(programArguments(plan.files[0]?.content ?? '')).toEqual([
      '/Users/test/.happier/bin/happier',
      'daemon',
      'start-sync',
      '--takeover',
    ]);
    expect(plan.darwinLauncherInstall).toBeUndefined();
  });
});

import { describe, expect, it } from 'vitest';

import { planDaemonServiceInstall } from './plan';

const baseInstallParams = {
  platform: 'linux',
  mode: 'user',
  channel: 'stable',
  userHomeDir: '/home/alice',
  happierHomeDir: '/home/alice/.happier',
  serverUrl: 'https://api.example.test',
  webappUrl: 'https://app.example.test',
  publicServerUrl: 'https://api.example.test',
  nodePath: '/usr/bin/node',
  entryPath: '/opt/happier/package-dist/index.mjs',
} as const;

describe('daemon service plan active server identity', () => {
  it('requires an explicit active server id for pinned installs instead of falling back to the service instance id', () => {
    expect(() => planDaemonServiceInstall({
      darwinLauncher: null,
      ...baseInstallParams,
      targetMode: 'pinned',
      instanceId: 'service-instance',
    })).toThrow(/active server id/i);
  });

  it('uses the explicit active server id for pinned service env while keeping the service instance id for the unit name', () => {
    const params = {
      ...baseInstallParams,
      targetMode: 'pinned',
      instanceId: 'service-instance',
      activeServerId: 'company-profile',
    } as const;

    const plan = planDaemonServiceInstall({ ...params, darwinLauncher: null });
    const file = plan.files[0];

    expect(file?.path).toContain('happier-daemon.service-instance.service');
    expect(file?.content).toContain('HAPPIER_ACTIVE_SERVER_ID=company-profile');
    expect(file?.content).not.toContain('HAPPIER_ACTIVE_SERVER_ID=service-instance');
  });

  it('allows default-following installs to omit active server id and pinned server env', () => {
    const plan = planDaemonServiceInstall({
      darwinLauncher: null,
      ...baseInstallParams,
      targetMode: 'default-following',
      instanceId: 'service-instance',
    });

    expect(plan.files[0]?.content).not.toContain('HAPPIER_ACTIVE_SERVER_ID=');
    expect(plan.files[0]?.path).toContain('happier-daemon.default.service');
  });
});

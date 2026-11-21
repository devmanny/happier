import { describe, expect, it } from 'vitest';

import { resolveSpawnChildEnvironment } from './resolveSpawnChildEnvironment';
import type { SpawnSessionOptions } from '@/rpc/handlers/registerSessionHandlers';

describe('resolveSpawnChildEnvironment (agent identity)', () => {
  it('hands the agent identity to the runner', async () => {
    const options: SpawnSessionOptions = {
      directory: '.',
      agentIdentity: { v: 1, id: 'a1', name: 'Julián', emoji: '🤖', description: 'Arquitecto' },
    };

    const result = await resolveSpawnChildEnvironment({
      options,
      profileEnvironmentVariables: {},
      daemonSpawnHooks: null,
      processEnv: {},
      logDebug: () => {},
      logInfo: () => {},
      logWarn: () => {},
      connectedServiceAuth: null,
    });

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(JSON.parse(result.extraEnvForChild.HAPPIER_AGENT_IDENTITY_JSON!)).toEqual(options.agentIdentity);
  });
});

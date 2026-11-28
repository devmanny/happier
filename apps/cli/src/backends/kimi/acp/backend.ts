import type { AcpSessionModelAdapter } from '@/agent/acp/AcpBackend';
import { createCatalogDefinedAcpBackend, type CatalogDefinedAcpBackendOptions } from '@/agent/acp/catalog/createCatalogDefinedAcpBackend';
import type { AgentBackend } from '@/agent/core';
import { requireCurrentKimiRuntime } from '@/backends/kimi/cli/runtimeDiscovery';

import { buildKimiAutonomousTurnHandlers, KIMI_AUTONOMOUS_TURNS_CAPABILITY } from './autonomousTurns';

export type KimiBackendOptions = CatalogDefinedAcpBackendOptions;

/** Kimi Code advertises a thinking model's effort levels as its `thinking` select. */
const kimiSessionModelAdapter: AcpSessionModelAdapter = {
  configOptionIds: { reasoning_effort: 'thinking' },
};

/** Current Kimi uses the shared ACP backend; executable classification and option ids are provider-owned. */
export function createKimiBackend(options: KimiBackendOptions): AgentBackend {
  return createCatalogDefinedAcpBackend('kimi', {
    ...options,
    sessionModelAdapter: kimiSessionModelAdapter,
    initializeClientCapabilitiesMeta: {
      ...options.initializeClientCapabilitiesMeta,
      [KIMI_AUTONOMOUS_TURNS_CAPABILITY]: true,
    },
    extensionHandlers: [...(options.extensionHandlers ?? []), ...buildKimiAutonomousTurnHandlers()],
    prepareProcessLaunch: async () => {
      const runtime = await requireCurrentKimiRuntime({
        processEnv: { ...process.env, ...options.env },
        cwd: options.cwd,
      });
      return { command: runtime.command, args: ['acp'] };
    },
  });
}

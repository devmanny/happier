import type { ChildProcess } from 'node:child_process';

import { query, type Query, type SDKUserMessage } from '@anthropic-ai/claude-agent-sdk';

import type {
  PreflightSessionCatalogsRaw,
  PreflightSessionControlsProbeParams,
} from '@/capabilities/probes/preflightSessionControlsProbeAdapterTypes';
import { resolveClaudeAgentSdkLaunch, spawnClaudeAgentSdkProcess } from '@/backends/claude/sdk/claudeAgentSdkProcess';
import { buildClaudeSubprocessEnv } from '@/backends/claude/spawn/buildClaudeSubprocessEnv';
import { resolveClaudeSettingSources } from '@/backends/claude/utils/resolveClaudeSettingSources';
import { PushableAsyncIterable } from '@/utils/PushableAsyncIterable';
import { resolveClaudeSessionEnvOverlay } from '../spawn/resolveClaudeSessionEnvOverlay';
import { remainingCatalogProbeMs, withCatalogProbeLifecycle } from '@/capabilities/probes/catalogProbeLifecycle';
import { killProcessTree } from '@/agent/runtime/process/killProcessTree';

/** Native initialization advertises slash commands; it does not advertise a typed skill-mention catalog. */
export async function probeClaudeCatalogs(params: PreflightSessionControlsProbeParams): Promise<PreflightSessionCatalogsRaw> {
  const processEnv = params.processEnv ?? process.env;
  const subprocessEnv = buildClaudeSubprocessEnv({
    baseEnv: processEnv,
    envOverlay: resolveClaudeSessionEnvOverlay({ claudeCodeIncludeInNativeHistory: params.accountSettings?.claudeCodeIncludeInNativeHistory === true }),
  });
  const messages = new PushableAsyncIterable<SDKUserMessage>();
  const abortController = new AbortController();
  const lifecycle: { response: Query | null } = { response: null };
  let signal: AbortSignal | undefined;
  const onAbort = () => abortController.abort(signal?.reason);
  let child: ChildProcess | undefined;
  let childClosed: Promise<void> | undefined;
  let cleanupPromise: Promise<void> | undefined;
  const cleanup = () => cleanupPromise ??= (async () => {
    signal?.removeEventListener('abort', onAbort);
    messages.end();
    try {
      lifecycle.response?.close();
    } finally {
      abortController.abort();
      if (child) await killProcessTree(child);
      await childClosed;
    }
  })();
  return await withCatalogProbeLifecycle(params, async (probeLifecycle): Promise<PreflightSessionCatalogsRaw> => {
    signal = probeLifecycle.signal;
    signal.addEventListener('abort', onAbort, { once: true });
    remainingCatalogProbeMs(probeLifecycle);
    const launch = await resolveClaudeAgentSdkLaunch(processEnv);
    remainingCatalogProbeMs(probeLifecycle);
    const response = query({
      prompt: messages,
      options: {
        cwd: params.cwd,
        env: subprocessEnv,
        pathToClaudeCodeExecutable: launch.pathToClaudeCodeExecutable,
        executable: 'node',
        abortController,
        persistSession: false,
        settingSources: resolveClaudeSettingSources(params.accountSettings ?? {}),
        spawnClaudeCodeProcess: (options) => {
          probeLifecycle.signal.throwIfAborted();
          // The SDK spawns with the selected preflight environment (`env` above), not ambient auth.
          const startedChild = spawnClaudeAgentSdkProcess(launch, options);
          child = startedChild;
          childClosed = new Promise<void>((resolve) => startedChild.once('close', () => resolve()));
          params.onNativeCleanup?.(cleanup);
          return startedChild;
        },
      },
    });
    lifecycle.response = response;
    return { commands: await response.supportedCommands(), skills: null };
  }, cleanup);
}

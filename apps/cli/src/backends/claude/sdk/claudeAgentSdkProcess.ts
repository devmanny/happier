import { spawn, type ChildProcessByStdio } from 'node:child_process';
import type { Readable, Writable } from 'node:stream';

import type { SpawnOptions as AgentSdkSpawnOptions } from '@anthropic-ai/claude-agent-sdk';
import { resolveWindowsCommandInvocation } from '@happier-dev/cli-common/process';

import { getDefaultClaudeCodePathForAgentSdk, isClaudeAgentSdkJavaScriptEntrypoint } from '@/backends/claude/sdk/utils';
import { ensureJavaScriptRuntimeExecutable } from '@/runtime/js/ensureJavaScriptRuntimeExecutable';
import { isBun } from '@/utils/runtime';

/**
 * How a short-lived, Happier-owned Agent SDK query launches Claude Code: the canonical Agent SDK
 * entrypoint, plus Happier's binary-safe JavaScript runtime when that entrypoint is a script.
 * Pass `executable: 'node'` and `spawnClaudeCodeProcess` to `query()`; the spawner maps the SDK's
 * `node` alias to this runtime.
 */
export type ClaudeAgentSdkLaunch = Readonly<{
  pathToClaudeCodeExecutable: string;
  runtimeExecutable: string | null;
}>;

export async function resolveClaudeAgentSdkLaunch(processEnv: NodeJS.ProcessEnv): Promise<ClaudeAgentSdkLaunch> {
  const pathToClaudeCodeExecutable = getDefaultClaudeCodePathForAgentSdk(processEnv);
  if (!isClaudeAgentSdkJavaScriptEntrypoint(pathToClaudeCodeExecutable)) {
    return { pathToClaudeCodeExecutable, runtimeExecutable: null };
  }
  const runtimeExecutable = await ensureJavaScriptRuntimeExecutable({ isBunRuntime: isBun(), processEnv });
  if (!runtimeExecutable) throw new Error('Claude Code requires a JavaScript runtime that is not available');
  return { pathToClaudeCodeExecutable, runtimeExecutable };
}

/**
 * Spawns the process the SDK asks for, with the environment the SDK built for it. Agent SDK
 * 0.2.123 derives `options.env` from the `env` given to `query()` (a copy, with no host
 * environment merged in when `env` is given) plus its own flags, e.g.
 * `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING` for `enableFileCheckpointing`, which Claude Code
 * requires before it rewinds files. Callers keep their selected environment authoritative by
 * passing it as `query({ options: { env } })`.
 */
export function spawnClaudeAgentSdkProcess(
  launch: ClaudeAgentSdkLaunch,
  options: AgentSdkSpawnOptions,
): ChildProcessByStdio<Writable, Readable, null> {
  let command = options.command;
  if (command === 'node') {
    if (!launch.runtimeExecutable) throw new Error('Claude SDK requested an unavailable JavaScript runtime');
    command = launch.runtimeExecutable;
  }
  const invocation = resolveWindowsCommandInvocation({ command, args: options.args, env: options.env });
  return spawn(invocation.command, invocation.args, {
    cwd: options.cwd,
    env: options.env,
    signal: options.signal,
    stdio: ['pipe', 'pipe', 'ignore'],
    windowsHide: true,
    ...(invocation.windowsVerbatimArguments ? { windowsVerbatimArguments: true } : {}),
  });
}

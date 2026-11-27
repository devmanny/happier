import { query, type SDKUserMessage } from '@anthropic-ai/claude-agent-sdk';
import { resolveVendorResumeIdFromSessionMetadata } from '@happier-dev/agents';
import { SESSION_RESTORE_FILES_ERROR_CODES, type SessionRestoreFilesRpcResult } from '@happier-dev/protocol';

import { resolveClaudeAgentSdkLaunch, spawnClaudeAgentSdkProcess, type ClaudeAgentSdkLaunch } from '@/backends/claude/sdk/claudeAgentSdkProcess';
import { buildClaudeSubprocessEnv } from '@/backends/claude/spawn/buildClaudeSubprocessEnv';
import type { SessionFileRestoreHandler } from '@/backends/fileRestore/sessionFileRestoreHandler';

import { resolveSessionClaudeConfigDir, resolveSessionClaudeTranscriptPath } from '../utils/claudeSessionTranscriptLocation';
import { requestClaudeRewindFiles, rewindClaudeFilesVerified } from './claudeRewindFiles';
import { resolveClaudeUserMessageCheckpoint } from './resolveClaudeUserMessageCheckpoint';

function notRestorable(reason: string): SessionRestoreFilesRpcResult {
  return { ok: true, restorable: false, reasonCode: 'no_checkpoint', reason };
}

function restoreFailed(reason: string): SessionRestoreFilesRpcResult {
  return { ok: false, errorCode: SESSION_RESTORE_FILES_ERROR_CODES.RESTORE_FAILED, errorMessage: reason };
}

/**
 * Host directives that make a resumed Claude continue the conversation on its own (re-run an
 * interrupted turn, send a resume prompt; Claude Code 2.1.326). The daemon's `CLAUDE_*`
 * environment passes through to Claude subprocesses, but a restore must never start a turn.
 */
const CLAUDE_RESUME_DIRECTIVE_ENV_PREFIX = 'CLAUDE_CODE_RESUME_';

function buildRestoreEnv(configDir: string): Record<string, string> {
  const env = buildClaudeSubprocessEnv({ envOverlay: { CLAUDE_CONFIG_DIR: configDir } });
  for (const key of Object.keys(env)) {
    if (key.startsWith(CLAUDE_RESUME_DIRECTIVE_ENV_PREFIX)) delete env[key];
  }
  return env;
}

/**
 * Restores in a one-off Agent SDK query that resumes the session without a model turn: the prompt
 * stream stays open and never yields, so Claude only answers the rewind control requests. It works
 * while the session's own terminal Claude is live and idle; at shutdown the resumed Claude
 * appends bookkeeping rows (`cost-state`, sometimes `tools-used`) to the transcript.
 *
 * The caller's cancellation aborts the query (the SDK then stops Claude) and settles any pending
 * control request; it is checked again right before the real rewind, the only step that changes
 * files.
 */
async function rewindInResumedClaudeSession(params: Readonly<{
  launch: ClaudeAgentSdkLaunch;
  claudeSessionId: string;
  cwd: string;
  configDir: string;
  promptUuid: string;
  dryRun: boolean;
  signal?: AbortSignal;
}>): Promise<SessionRestoreFilesRpcResult> {
  const { signal } = params;
  signal?.throwIfAborted();
  const env = buildRestoreEnv(params.configDir);
  const abortController = new AbortController();
  const onAbort = () => abortController.abort(signal?.reason);
  signal?.addEventListener('abort', onAbort, { once: true });
  let releasePrompt = () => {};
  const promptReleased = new Promise<void>((resolve) => {
    releasePrompt = resolve;
  });
  async function* noPrompt(): AsyncGenerator<SDKUserMessage, void, unknown> {
    await promptReleased;
  }
  try {
    const session = query({
      prompt: noPrompt(),
      options: {
        resume: params.claudeSessionId,
        cwd: params.cwd,
        enableFileCheckpointing: true,
        // No hooks, plugins, permission settings or MCP servers of the user's configuration.
        settingSources: [],
        strictMcpConfig: true,
        env,
        abortController,
        pathToClaudeCodeExecutable: params.launch.pathToClaudeCodeExecutable,
        executable: 'node',
        spawnClaudeCodeProcess: (options) => spawnClaudeAgentSdkProcess(params.launch, options),
      },
    });
    try {
      const preview = await requestClaudeRewindFiles(session, params.promptUuid, { dryRun: true, signal });
      if (preview.status === 'failed') return restoreFailed(preview.reason);
      if (preview.status === 'not_rewindable') return notRestorable(preview.reason);
      const changes = {
        filesChanged: preview.filesChanged,
        ...(preview.insertions !== undefined ? { insertions: preview.insertions } : {}),
        ...(preview.deletions !== undefined ? { deletions: preview.deletions } : {}),
      };
      if (params.dryRun) return { ok: true, restorable: true, restored: false, ...changes };

      signal?.throwIfAborted();
      // A real rewind reports no file list; once verified complete, the dry run's list is what it restored.
      const restore = await rewindClaudeFilesVerified(session, params.promptUuid, { signal });
      if (restore.status !== 'ok') return restoreFailed(restore.reason);
      return { ok: true, restorable: true, restored: true, ...changes };
    } finally {
      releasePrompt();
      session.close();
    }
  } finally {
    signal?.removeEventListener('abort', onAbort);
  }
}

export const restoreClaudeSessionFiles: SessionFileRestoreHandler = async (params) => {
  const claudeSessionId = resolveVendorResumeIdFromSessionMetadata('claude', params.metadata);
  if (!claudeSessionId || /[\\/]/.test(claudeSessionId)) {
    return notRestorable('This session has no Claude conversation to restore from.');
  }
  const configDir = resolveSessionClaudeConfigDir(params.metadata);
  const checkpoint = await resolveClaudeUserMessageCheckpoint({
    credentials: params.credentials,
    sessionId: params.sessionId,
    rawSession: params.rawSession,
    userMessageSeq: params.userMessageSeq,
    directory: params.directory,
    transcriptPath: resolveSessionClaudeTranscriptPath({
      metadata: params.metadata,
      configDir,
      directory: params.directory,
      claudeSessionId,
    }),
  });
  if (checkpoint.status === 'missing') return notRestorable(checkpoint.reason);

  let launch: ClaudeAgentSdkLaunch;
  try {
    launch = await resolveClaudeAgentSdkLaunch(process.env);
  } catch (error) {
    return restoreFailed(error instanceof Error ? error.message : 'Claude Code is not available on this machine.');
  }
  return await rewindInResumedClaudeSession({
    launch,
    claudeSessionId,
    cwd: params.directory,
    configDir,
    promptUuid: checkpoint.promptUuid,
    dryRun: params.dryRun,
    ...(params.signal ? { signal: params.signal } : {}),
  });
};

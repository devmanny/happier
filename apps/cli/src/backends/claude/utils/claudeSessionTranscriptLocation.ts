import { isAbsolute, join, relative } from 'node:path';

import { resolveHomeDirFromEnvironment } from '@happier-dev/cli-common/providers';

import { readSessionNativeEnvironment } from '@/agent/runtime/sessionNativeEnvironment';

import { resolveClaudeConnectedServiceCandidatePersistedSessionFile } from '../connectedServices/resolveClaudeConnectedServiceCandidatePersistedSessionFile';
import { getProjectPath } from './path';

/**
 * The session's Claude config dir decides where its transcript and file backups live, so it must
 * come from the session: metadata records `CLAUDE_CONFIG_DIR` only when the session ran with one,
 * and its absence means Claude's default home dir. The daemon's own environment is not the
 * session's. (With the wrong dir a file-restore dry run can still report `canRewind: true`.)
 */
export function resolveSessionClaudeConfigDir(metadata: Readonly<Record<string, unknown>>): string {
  return readSessionNativeEnvironment(metadata.nativeAgentEnvironmentV1)?.CLAUDE_CONFIG_DIR
    ?? join(resolveHomeDirFromEnvironment(process.env), '.claude');
}

/** The session's Claude transcript file, inside `configDir`. */
export function resolveSessionClaudeTranscriptPath(params: Readonly<{
  metadata: Readonly<Record<string, unknown>>;
  configDir: string;
  directory: string;
  claudeSessionId: string;
}>): string {
  // Prefer the path Claude itself reported, while it belongs to `configDir`.
  const reported = resolveClaudeConnectedServiceCandidatePersistedSessionFile({ metadata: params.metadata });
  if (reported) {
    const withinProjects = relative(join(params.configDir, 'projects'), reported);
    if (withinProjects && !withinProjects.startsWith('..') && !isAbsolute(withinProjects)) return reported;
  }
  return join(getProjectPath(params.directory, params.configDir), `${params.claudeSessionId}.jsonl`);
}

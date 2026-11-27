import { createReadStream } from 'node:fs';
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createInterface } from 'node:readline';

import { forkSession, type SessionStore, type SessionStoreEntry } from '@anthropic-ai/claude-agent-sdk';
import { resolveVendorResumeIdFromSessionMetadata } from '@happier-dev/agents';

import { readSessionNativeEnvironment } from '@/agent/runtime/sessionNativeEnvironment';
import {
  ProviderNativeForkFailedBeforeDispatchError,
  type ProviderNativeForkHandler,
} from '@/backends/forking/providerNativeForkHandler';
import type { Credentials } from '@/persistence';
import { fetchEncryptedTranscriptMessagesPage } from '@/session/replay/fetchEncryptedTranscriptMessages';
import { logger } from '@/ui/logger';

import { extractClaudeJsonlMessageKeyFromLocalId } from '../utils/claudeJsonlMessageKey';
import { resolveSessionClaudeConfigDir, resolveSessionClaudeTranscriptPath } from '../utils/claudeSessionTranscriptLocation';
import { getProjectPath } from '../utils/path';

/**
 * Claude's native fork: the Agent SDK's `forkSession` copies the parent conversation into a new
 * Claude session (fresh uuids, each copied row marked `forkedFrom`), cut at one message, and the
 * child resumes it. The child keeps the whole conversation instead of a replayed text tail.
 *
 * The cut follows the fork lineage: the child shows the parent's Happier rows up to
 * `cutoffSeqInclusive`, so Claude keeps its conversation up to the last Claude row the runner
 * committed at or before that seq (`claude-jsonl:main:<type>:<uuid>`). If that row is not in the
 * session's current Claude conversation (the cutoff predates a `/clear` or a new Claude session),
 * the fork is left to replay.
 *
 * `forkSession` reads the config dir from the daemon's own environment, so the fork goes through
 * a session store bound to this session's transcript file and Claude home instead.
 */

const PAGE_LIMIT = 150;
const CLAUDE_UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAIN_CHAIN_MESSAGE_KEY = /^main:(?:user|assistant|attachment|system):(.+)$/;
/** Row types `forkSession` keeps as conversation messages. */
const CLAUDE_CONVERSATION_ROW_TYPES = new Set(['user', 'assistant', 'attachment', 'system']);

function skip(reason: string, details: Record<string, unknown>): null {
  logger.debug('[ClaudeNativeFork] leaving the fork to replay', { reason, ...details });
  return null;
}

function readClaudeMessageUuid(localId: unknown): string | null {
  const key = extractClaudeJsonlMessageKeyFromLocalId(typeof localId === 'string' ? localId : null);
  const uuid = key ? MAIN_CHAIN_MESSAGE_KEY.exec(key)?.[1] : undefined;
  return uuid && CLAUDE_UUID_PATTERN.test(uuid) ? uuid : null;
}

/** Streams the transcript (it can exceed 100 MB) for its main-chain conversation message uuids. */
async function readMainChainMessageUuids(transcriptPath: string): Promise<Set<string>> {
  const uuids = new Set<string>();
  const input = createReadStream(transcriptPath, { encoding: 'utf8' });
  const lines = createInterface({ input, crlfDelay: Infinity });
  try {
    for await (const line of lines) {
      let row: unknown;
      try {
        row = JSON.parse(line);
      } catch {
        continue;
      }
      if (!row || typeof row !== 'object') continue;
      const record = row as Record<string, unknown>;
      if (typeof record.uuid === 'string' && record.isSidechain !== true && CLAUDE_CONVERSATION_ROW_TYPES.has(String(record.type))) {
        uuids.add(record.uuid);
      }
    }
    return uuids;
  } finally {
    lines.close();
    input.destroy();
  }
}

/** Newest Claude row at or before the cutoff, when it belongs to `conversationUuids`. */
async function resolveForkMessageUuid(params: Readonly<{
  credentials: Credentials;
  sessionId: string;
  cutoffSeqInclusive: number;
  conversationUuids: ReadonlySet<string>;
}>): Promise<string | null> {
  let beforeSeq: number | null = params.cutoffSeqInclusive + 1;
  while (beforeSeq !== null) {
    const page = await fetchEncryptedTranscriptMessagesPage({
      token: params.credentials.token,
      sessionId: params.sessionId,
      limit: PAGE_LIMIT,
      beforeSeq,
      scope: 'main',
    });
    const newestFirst = [...page.messages].sort((a, b) => Number(b.seq) - Number(a.seq));
    for (const row of newestFirst) {
      const uuid = readClaudeMessageUuid(row.localId);
      if (uuid) return params.conversationUuids.has(uuid) ? uuid : null;
    }
    beforeSeq = page.hasMore ? page.nextBeforeSeq : null;
  }
  return null;
}

async function readTranscriptEntries(path: string): Promise<SessionStoreEntry[]> {
  const entries: SessionStoreEntry[] = [];
  const input = createReadStream(path, { encoding: 'utf8' });
  const lines = createInterface({ input, crlfDelay: Infinity });
  try {
    for await (const line of lines) {
      try {
        const value: unknown = JSON.parse(line);
        if (value && typeof value === 'object' && typeof (value as Record<string, unknown>).type === 'string') {
          entries.push(value as SessionStoreEntry);
        }
      } catch {
        // Claude skips unparseable lines too.
      }
    }
    return entries;
  } finally {
    lines.close();
    input.destroy();
  }
}

/**
 * Reads only the parent transcript and writes only new sessions' transcripts, into the project
 * dir Claude resumes from for this directory and Claude home. Never overwrites a file.
 */
function createForkSessionStore(params: Readonly<{
  parentClaudeSessionId: string;
  parentTranscriptPath: string;
  targetProjectDir: string;
}>): SessionStore {
  return {
    async load(key) {
      if (key.subpath !== undefined || key.sessionId !== params.parentClaudeSessionId) return null;
      return await readTranscriptEntries(params.parentTranscriptPath);
    },
    async append(key, entries) {
      if (key.subpath !== undefined || key.sessionId === params.parentClaudeSessionId || !CLAUDE_UUID_PATTERN.test(key.sessionId)) {
        throw new Error('Claude fork may only write a new session transcript');
      }
      await mkdir(params.targetProjectDir, { recursive: true });
      await writeFile(
        join(params.targetProjectDir, `${key.sessionId}.jsonl`),
        entries.map((entry) => `${JSON.stringify(entry)}\n`).join(''),
        { flag: 'wx', mode: 0o600 },
      );
    },
  };
}

function hasConnectedServices(metadata: Readonly<Record<string, unknown>>): boolean {
  const services = metadata.connectedServices;
  if (!services || typeof services !== 'object') return false;
  const bindings = (services as Record<string, unknown>).bindingsByServiceId;
  return Boolean(bindings && typeof bindings === 'object' && Object.keys(bindings).length > 0);
}

export const claudeProviderNativeForkHandler: ProviderNativeForkHandler = async (params) => {
  const details = { parentSessionId: params.parentSessionId, cutoffSeqInclusive: params.cutoffSeqInclusive };
  const parentClaudeSessionId = resolveVendorResumeIdFromSessionMetadata('claude', params.parentMetadata) ?? '';
  if (!CLAUDE_UUID_PATTERN.test(parentClaudeSessionId)) return skip('no_claude_conversation', details);
  // A connected service can run the child under another Claude home than the parent's transcript.
  if (hasConnectedServices(params.parentMetadata)) return skip('connected_services', details);

  const configDir = resolveSessionClaudeConfigDir(params.parentMetadata);
  const parentTranscriptPath = resolveSessionClaudeTranscriptPath({
    metadata: params.parentMetadata,
    configDir,
    directory: params.directory,
    claudeSessionId: parentClaudeSessionId,
  });
  let conversationUuids: Set<string>;
  try {
    conversationUuids = await readMainChainMessageUuids(parentTranscriptPath);
  } catch (error) {
    const code = error && typeof error === 'object' && 'code' in error ? String(error.code) : 'unreadable';
    return skip('transcript_unreadable', { ...details, code });
  }
  params.signal?.throwIfAborted();

  const upToMessageId = await resolveForkMessageUuid({
    credentials: params.credentials,
    sessionId: params.parentSessionId,
    cutoffSeqInclusive: params.cutoffSeqInclusive,
    conversationUuids,
  });
  if (!upToMessageId) return skip('cutoff_outside_current_claude_conversation', details);
  params.signal?.throwIfAborted();

  let vendorSessionId: string;
  try {
    ({ sessionId: vendorSessionId } = await forkSession(parentClaudeSessionId, {
      upToMessageId,
      sessionStore: createForkSessionStore({
        parentClaudeSessionId,
        parentTranscriptPath,
        targetProjectDir: getProjectPath(params.directory, configDir),
      }),
    }));
  } catch (error) {
    throw new ProviderNativeForkFailedBeforeDispatchError(
      error instanceof Error ? error : new Error('Claude could not fork the conversation'),
    );
  }

  // Only a Claude home the parent ran with explicitly is pinned on the child: setting
  // CLAUDE_CONFIG_DIR, even to the default dir, can change where Claude Code looks up its credentials.
  const sessionConfigDir = readSessionNativeEnvironment(params.parentMetadata.nativeAgentEnvironmentV1)?.CLAUDE_CONFIG_DIR;
  logger.debug('[ClaudeNativeFork] forked the Claude conversation', details);
  return {
    vendorSessionId,
    spawn: {
      resume: vendorSessionId,
      ...(sessionConfigDir ? { environmentVariables: { CLAUDE_CONFIG_DIR: sessionConfigDir } } : {}),
    },
    metadata: { claudeSessionId: vendorSessionId },
    providerHint: { providerId: params.agentId, vendorSessionId },
  };
};

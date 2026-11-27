import { createReadStream } from 'node:fs';
import { createInterface } from 'node:readline';

import { isHappierProviderOnlyPromptSuffix } from '@/agent/runtime/prompt/resolveProviderPromptForDispatch';
import { fetchEncryptedTranscriptPageAfterSeq, type TranscriptRow } from '@/api/session/fetchEncryptedTranscriptWindow';
import type { Credentials } from '@/persistence';
import { decryptTranscriptRows } from '@/session/replay/decryptTranscriptRows';
import { resolveSessionEncryptionContextFromCredentials } from '@/session/transport/encryption/sessionEncryptionContext';
import { resolvePathForComparison } from '@/utils/path/normalizePathForComparison';

import { normalizeClaudeUnifiedPromptIdentityText } from '../unifiedTerminal/promptIdentity';
import { extractClaudeJsonlMessageKeyFromLocalId } from '../utils/claudeJsonlMessageKey';

/**
 * Claude keeps a file checkpoint per main-chain prompt, keyed by the prompt row's transcript uuid
 * (`file-history-snapshot.messageId`). Happier user message N reaches that uuid through the row
 * the unified runner commits for Claude's prompt row (`claude-jsonl:main:user:<uuid>`): a marker
 * committed after N when Happier delivered the prompt and suppressed Claude's echo, or N itself
 * when the prompt was typed in the terminal. The first such row at or after N is the only
 * candidate; it belongs to N only when Claude's prompt row says so:
 * - a prompt typed in the terminal is a user message of its own, so it can only be N itself;
 * - a delivered prompt is exactly what the runner sends for one queue batch: an optional replay
 *   seed joined by a blank line, the batched messages joined by newlines, then optionally the
 *   provider-only context Happier appends. Every message from N up to the candidate must appear
 *   there contiguously, N starting a line (an earlier member of the same batch may precede it);
 * - a steer has no prompt of its own, so the next candidate is a tool result or a later prompt,
 *   and fails that check.
 * The prompt must also have run in the session's working directory, because Claude resolves the
 * checkpointed paths against the working directory of whoever restores them.
 */
const CLAUDE_MAIN_USER_KEY_PREFIX = 'main:user:';

/** Transport page size for the forward walk; the walk continues until it finds a candidate. */
const TRANSCRIPT_PAGE_LIMIT = 150;

export type ClaudeUserMessageCheckpoint =
  | Readonly<{ status: 'found'; promptUuid: string }>
  | Readonly<{ status: 'missing'; reason: string }>;

const NO_PROMPT_OF_ITS_OWN = 'This message has no prompt of its own in the Claude conversation.';

function readUserMessageText(content: unknown): string {
  if (!content || typeof content !== 'object' || Array.isArray(content)) return '';
  const record = content as Record<string, unknown>;
  return record.type === 'text' && typeof record.text === 'string'
    ? normalizeClaudeUnifiedPromptIdentityText(record.text)
    : '';
}

function readClaudePromptUuid(localId: string | null | undefined): string | null {
  const key = extractClaudeJsonlMessageKeyFromLocalId(localId);
  if (!key?.startsWith(CLAUDE_MAIN_USER_KEY_PREFIX)) return null;
  const uuid = key.slice(CLAUDE_MAIN_USER_KEY_PREFIX.length);
  return uuid.length > 0 ? uuid : null;
}

/** Whether `promptText` is the prompt delivered for exactly these consecutive messages (see above). */
function isPromptForMessages(promptText: string, messageTexts: readonly string[]): boolean {
  const [first, ...rest] = messageTexts;
  if (!first) return false;
  for (let start = promptText.indexOf(first); start >= 0; start = promptText.indexOf(first, start + 1)) {
    if (start > 0 && promptText[start - 1] !== '\n') continue;
    let end = start + first.length;
    let contiguous = true;
    for (const text of rest) {
      const gap = /^\s+/.exec(promptText.slice(end))?.[0].length ?? 0;
      if (gap === 0 || !promptText.startsWith(text, end + gap)) {
        contiguous = false;
        break;
      }
      end += gap + text.length;
    }
    if (!contiguous) continue;
    const tail = promptText.slice(end);
    if (tail === '' || (tail.startsWith('\n\n') && isHappierProviderOnlyPromptSuffix(tail.slice(2)))) return true;
  }
  return false;
}

async function isWithinDirectory(path: string, directory: string): Promise<boolean> {
  const [candidate, root] = await Promise.all([resolvePathForComparison(path), resolvePathForComparison(directory)]);
  if (!candidate || !root) return false;
  return candidate === root || candidate.startsWith(root.endsWith('/') ? root : `${root}/`);
}

type ClaudeMainChainPrompt = Readonly<{ text: string; cwd: string | null }>;

/** Streams the transcript (it can exceed 100 MB) and returns the main-chain prompt row `uuid`. */
async function readClaudeMainChainPrompt(transcriptPath: string, uuid: string): Promise<ClaudeMainChainPrompt | null> {
  const input = createReadStream(transcriptPath, { encoding: 'utf8' });
  const lines = createInterface({ input, crlfDelay: Infinity });
  try {
    for await (const line of lines) {
      if (!line.includes(uuid)) continue;
      let row: unknown;
      try {
        row = JSON.parse(line);
      } catch {
        continue;
      }
      if (!row || typeof row !== 'object' || (row as Record<string, unknown>).uuid !== uuid) continue;
      const record = row as Record<string, unknown>;
      const message = record.message as Record<string, unknown> | undefined;
      const isMainChainPrompt = record.type === 'user'
        && record.isSidechain !== true
        && record.isMeta !== true
        && typeof message?.content === 'string';
      if (!isMainChainPrompt) return null;
      return {
        text: normalizeClaudeUnifiedPromptIdentityText(message!.content as string),
        cwd: typeof record.cwd === 'string' && record.cwd.trim() ? record.cwd : null,
      };
    }
    return null;
  } finally {
    lines.close();
    input.destroy();
  }
}

export async function resolveClaudeUserMessageCheckpoint(params: Readonly<{
  credentials: Credentials;
  sessionId: string;
  rawSession: Readonly<{ encryptionMode?: unknown; dataEncryptionKey?: unknown }>;
  userMessageSeq: number;
  transcriptPath: string;
  /** The session's working directory, where the restore resolves Claude's checkpointed paths. */
  directory: string;
}>): Promise<ClaudeUserMessageCheckpoint> {
  const ctx = resolveSessionEncryptionContextFromCredentials(params.credentials, params.rawSession);
  const decryptRow = (row: TranscriptRow) => decryptTranscriptRows({ ctx, rows: [row] })[0] ?? null;

  const messageTexts: string[] = [];
  let promptUuid: string | null = null;
  let afterSeq = params.userMessageSeq - 1;
  while (promptUuid === null) {
    const page = await fetchEncryptedTranscriptPageAfterSeq({
      token: params.credentials.token,
      sessionId: params.sessionId,
      afterSeq,
      limit: TRANSCRIPT_PAGE_LIMIT,
    });
    if (page.length === 0) break;
    for (const row of page) {
      const decrypted = decryptRow(row);
      const rowPromptUuid = readClaudePromptUuid(row.localId);
      if (row.seq === params.userMessageSeq) {
        const text = decrypted?.role === 'user' ? readUserMessageText(decrypted.content) : '';
        if (!text) return { status: 'missing', reason: `Message ${params.userMessageSeq} is not a user message with text.` };
        messageTexts.push(text);
      } else if (messageTexts.length === 0) {
        return { status: 'missing', reason: `Message ${params.userMessageSeq} was not found.` };
      } else if (decrypted?.role === 'user') {
        // A later prompt typed in the terminal is that message's own prompt, never N's.
        if (rowPromptUuid) return { status: 'missing', reason: NO_PROMPT_OF_ITS_OWN };
        const text = readUserMessageText(decrypted.content);
        if (text) messageTexts.push(text);
      }
      promptUuid = rowPromptUuid;
      if (promptUuid) break;
    }
    afterSeq = page[page.length - 1]!.seq;
  }

  if (messageTexts.length === 0) {
    return { status: 'missing', reason: `Message ${params.userMessageSeq} was not found.` };
  }
  if (!promptUuid) {
    return { status: 'missing', reason: 'Claude has not recorded this message as a prompt yet.' };
  }
  let prompt: ClaudeMainChainPrompt | null;
  try {
    prompt = await readClaudeMainChainPrompt(params.transcriptPath, promptUuid);
  } catch (error) {
    const code = error && typeof error === 'object' && 'code' in error ? String(error.code) : 'unreadable';
    return { status: 'missing', reason: `The Claude conversation file could not be read on this machine (${code}).` };
  }
  if (prompt === null || !isPromptForMessages(prompt.text, messageTexts)) {
    return { status: 'missing', reason: NO_PROMPT_OF_ITS_OWN };
  }
  if (!prompt.cwd || !await isWithinDirectory(prompt.cwd, params.directory)) {
    return { status: 'missing', reason: 'Claude ran this prompt outside the session\'s working directory.' };
  }
  return { status: 'found', promptUuid };
}

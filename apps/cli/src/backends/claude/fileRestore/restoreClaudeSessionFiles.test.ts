import { chmod, mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import type { RewindFilesResult } from '@anthropic-ai/claude-agent-sdk';
import { HAPPIER_SESSION_REFERENCE_OPEN_TAG } from '@/agent/runtime/prompt/sessionReferenceBlock';
import { getProjectPath } from '@/backends/claude/utils/path';
import type { Credentials } from '@/persistence';
import type { TranscriptRow } from '@/api/session/fetchEncryptedTranscriptWindow';
import { createEnvKeyScope } from '@/testkit/env/envScope';
import { createTempDir, removeTempDir } from '@/testkit/fs/tempDir';

/**
 * Boundaries: the server's `GET /v1/sessions/:id/messages` client and the Claude Agent SDK
 * `query()`. The seq -> checkpoint mapping, the real transcript file read and the rewind result
 * interpretation stay real underneath them.
 */
const fetchEncryptedTranscriptPageAfterSeq = vi.hoisted(() => vi.fn());
const sdkQuery = vi.hoisted(() => vi.fn());

vi.mock('@/api/session/fetchEncryptedTranscriptWindow', async (importOriginal) => ({
  ...await importOriginal<typeof import('@/api/session/fetchEncryptedTranscriptWindow')>(),
  fetchEncryptedTranscriptPageAfterSeq,
}));

vi.mock('@anthropic-ai/claude-agent-sdk', async (importOriginal) => ({
  ...await importOriginal<typeof import('@anthropic-ai/claude-agent-sdk')>(),
  query: sdkQuery,
}));

import { restoreClaudeSessionFiles } from './restoreClaudeSessionFiles';

const CLAUDE_SESSION_ID = '7b1f0c2e-1111-4222-8333-944445555666';
const credentials = { token: 'token-1', encryption: { type: 'legacy', secret: new Uint8Array(32).fill(3) } } as Credentials;

type ServerRow = Readonly<{ seq: number; localId: string; role: 'user' | 'agent'; text?: string }>;

/** Rows exactly as the main-chain listing returns them, plaintext session. */
function toTranscriptRow(row: ServerRow): TranscriptRow {
  const body = row.role === 'user'
    ? { role: 'user', content: { type: 'text', text: row.text ?? '' }, meta: { sentFrom: 'ui' } }
    : {
      role: 'agent',
      content: { type: 'output', data: { type: 'progress', marker: 'claude_jsonl_consumed_marker' } },
      meta: { source: 'cli' },
    };
  return { seq: row.seq, createdAt: 1_700_000_000_000 + row.seq, localId: row.localId, content: { t: 'plain', v: body } as TranscriptRow['content'] };
}

const userPrompt = (uuid: string, content: unknown, extra: Record<string, unknown> = {}) => ({
  type: 'user',
  uuid,
  parentUuid: null,
  isSidechain: false,
  sessionId: CLAUDE_SESSION_ID,
  message: { role: 'user', content },
  ...extra,
});

/**
 * One parent conversation covering every mapping shape:
 * - 1: Happier prompt delivered while idle, echo suppressed -> marker at 2;
 * - 4: typed in the TUI, published with Claude's own localId;
 * - 5 + 6: one batched prompt (the queue joins messages with a newline) -> marker at 7;
 * - 8: steer while busy -> the next Claude user row is a tool result (9);
 * - 10: steer whose text overlaps the next prompt (11) -> marker at 12;
 * - 13: marker points at a prompt with different text;
 * - 15: steer followed by a prompt typed in the TUI (16) that starts with the steer's text;
 * - 17, 19: messages that ran on another Agent (18 is its reply); 20 returned to Claude with a
 *   replay seed that quotes 17 and 19 -> marker at 21;
 * - 22: marker points at a later prompt that only begins with the message;
 * - 24: delivered with Happier's provider-only context appended -> marker at 25;
 * - 26: marker points at a prompt Claude ran in another working directory;
 * - 28: last message, no marker yet.
 */
const SERVER_ROWS: ServerRow[] = [
  { seq: 1, localId: 'local-1', role: 'user', text: 'Refactor the parser' },
  { seq: 2, localId: 'claude-jsonl:main:user:u-prompt-1', role: 'agent' },
  { seq: 3, localId: 'claude-jsonl:main:assistant:a-1', role: 'agent' },
  { seq: 4, localId: 'claude-jsonl:main:user:u-typed', role: 'user', text: 'typed in the terminal' },
  { seq: 5, localId: 'local-5', role: 'user', text: 'part one' },
  { seq: 6, localId: 'local-6', role: 'user', text: 'part two' },
  { seq: 7, localId: 'claude-jsonl:main:user:u-batch', role: 'agent' },
  { seq: 8, localId: 'local-8', role: 'user', text: 'also run the tests' },
  { seq: 9, localId: 'claude-jsonl:main:user:u-tool-result', role: 'agent' },
  { seq: 10, localId: 'local-10', role: 'user', text: 'ok' },
  { seq: 11, localId: 'local-11', role: 'user', text: 'ok go' },
  { seq: 12, localId: 'claude-jsonl:main:user:u-ok-go', role: 'agent' },
  { seq: 13, localId: 'local-13', role: 'user', text: 'rename the module' },
  { seq: 14, localId: 'claude-jsonl:main:user:u-other', role: 'agent' },
  { seq: 15, localId: 'local-15', role: 'user', text: 'ship' },
  { seq: 16, localId: 'claude-jsonl:main:user:u-typed-ship-it', role: 'user', text: 'ship it' },
  { seq: 17, localId: 'local-17', role: 'user', text: 'first codex ask' },
  { seq: 18, localId: 'codex-reply-18', role: 'agent' },
  { seq: 19, localId: 'local-19', role: 'user', text: 'second codex ask' },
  { seq: 20, localId: 'local-20', role: 'user', text: 'back on claude' },
  { seq: 21, localId: 'claude-jsonl:main:user:u-seeded', role: 'agent' },
  { seq: 22, localId: 'local-22', role: 'user', text: 'run it' },
  { seq: 23, localId: 'claude-jsonl:main:user:u-run-it-and-deploy', role: 'agent' },
  { seq: 24, localId: 'local-24', role: 'user', text: 'with context' },
  { seq: 25, localId: 'claude-jsonl:main:user:u-with-context', role: 'agent' },
  { seq: 26, localId: 'local-26', role: 'user', text: 'moved away' },
  { seq: 27, localId: 'claude-jsonl:main:user:u-elsewhere', role: 'agent' },
  { seq: 28, localId: 'local-28', role: 'user', text: 'and the docs' },
];

/** Claude records the working directory on every prompt row; `cwd: null` keeps the session's. */
function transcriptRows(directory: string, elsewhere: string): Record<string, unknown>[] {
  return [
    { type: 'file-history-snapshot', messageId: 'u-prompt-1', snapshot: { trackedFileBackups: {} } },
    userPrompt('u-prompt-1', 'Refactor the parser'),
    { type: 'assistant', uuid: 'a-1', parentUuid: 'u-prompt-1', message: { role: 'assistant', content: [] } },
    userPrompt('u-typed', 'typed in the terminal'),
    userPrompt('u-batch', '<pasted_content id="9b65">\npart one\npart two\n</pasted_content id="9b65">'),
    userPrompt('u-tool-result', [{ type: 'tool_result', tool_use_id: 'toolu_1', content: 'also run the tests' }]),
    userPrompt('u-ok-go', 'ok go'),
    userPrompt('u-other', 'something else entirely'),
    userPrompt('u-typed-ship-it', 'ship it'),
    userPrompt('u-seeded', [
      '<session_context>',
      'User: first codex ask',
      'Assistant: Done.',
      'User: second codex ask',
      '</session_context>',
      '',
      'back on claude',
    ].join('\n')),
    userPrompt('u-run-it-and-deploy', 'run it and then deploy'),
    userPrompt('u-with-context', `with context\n\n${HAPPIER_SESSION_REFERENCE_OPEN_TAG}\nsess_other\n</happier_session_reference>`),
    userPrompt('u-elsewhere', 'moved away', { cwd: elsewhere }),
  ].map((row) => (row.type === 'user' && !('cwd' in row) ? { ...row, cwd: join(directory, 'src') } : row));
}

type FakeQuery = {
  rewindFiles: ReturnType<typeof vi.fn<(id: string, options?: { dryRun?: boolean }) => Promise<RewindFilesResult>>>;
  close: ReturnType<typeof vi.fn>;
  [Symbol.asyncIterator]: () => AsyncGenerator<never, void, unknown>;
};

function primeSdkQuery(rewind: (id: string, options?: { dryRun?: boolean }) => Promise<RewindFilesResult>): FakeQuery {
  const fake: FakeQuery = {
    rewindFiles: vi.fn(rewind),
    close: vi.fn(),
    async *[Symbol.asyncIterator]() {},
  };
  sdkQuery.mockReturnValue(fake);
  return fake;
}

const DRY_RUN_RESULT: RewindFilesResult = {
  canRewind: true,
  filesChanged: ['/repo/src/parser.ts', '/repo/src/lexer.ts'],
  insertions: 12,
  deletions: 4,
};

/**
 * Claude Code 2.1.326: a dry run lists every file that differs from the checkpoint; a real
 * rewind answers `{ canRewind: true }` once any file was restored. `notRestored` are the files
 * the real rewind could not restore (missing backup, write failure, link-safety refusal).
 */
function claudeRewind(notRestored: string[] = []) {
  let rewound = false;
  return async (_id: string, options?: { dryRun?: boolean }): Promise<RewindFilesResult> => {
    if (!options?.dryRun) {
      rewound = true;
      return { canRewind: true };
    }
    if (!rewound) return DRY_RUN_RESULT;
    return { canRewind: true, filesChanged: notRestored, insertions: 0, deletions: notRestored.length };
  };
}

describe('restoreClaudeSessionFiles', () => {
  const env = createEnvKeyScope(['HAPPIER_CLAUDE_PATH', 'CLAUDE_CONFIG_DIR', 'HOME']);
  let root = '';
  let configDir = '';
  let directory = '';
  let transcriptPath = '';
  let claudeExecutable = '';
  let homeDir = '';

  beforeEach(async () => {
    root = await createTempDir('happier-claude-restore-');
    configDir = join(root, 'claude-config');
    directory = join(root, 'repo');
    transcriptPath = join(configDir, 'projects', '-repo', `${CLAUDE_SESSION_ID}.jsonl`);
    claudeExecutable = join(root, 'claude');
    await mkdir(join(configDir, 'projects', '-repo'), { recursive: true });
    await mkdir(join(directory, 'src'), { recursive: true });
    homeDir = join(root, 'home');
    const rows = transcriptRows(directory, join(root, 'other-checkout'));
    await writeFile(transcriptPath, `${rows.map((row) => JSON.stringify(row)).join('\n')}\n`);
    await writeFile(claudeExecutable, '#!/bin/sh\nexit 0\n');
    await chmod(claudeExecutable, 0o755);
    // The daemon's own Claude config dir is not the session's.
    env.patch({ HAPPIER_CLAUDE_PATH: claudeExecutable, CLAUDE_CONFIG_DIR: join(root, 'daemon-claude-config') });

    sdkQuery.mockReset();
    fetchEncryptedTranscriptPageAfterSeq.mockReset();
    fetchEncryptedTranscriptPageAfterSeq.mockImplementation(async (params: { afterSeq: number; limit: number }) => (
      SERVER_ROWS.filter((row) => row.seq > params.afterSeq).slice(0, params.limit).map(toTranscriptRow)
    ));
  });

  afterEach(async () => {
    env.restore();
    await removeTempDir(root);
  });

  const restore = (
    userMessageSeq: number,
    dryRun: boolean,
    overrides: Readonly<{ metadata?: Record<string, unknown>; signal?: AbortSignal }> = {},
  ) => restoreClaudeSessionFiles({
    credentials,
    sessionId: 'sess_parent',
    rawSession: { encryptionMode: 'plain' },
    metadata: overrides.metadata ?? {
      path: directory,
      flavor: 'claude',
      claudeSessionId: CLAUDE_SESSION_ID,
      claudeTranscriptPath: transcriptPath,
      nativeAgentEnvironmentV1: { CLAUDE_CONFIG_DIR: configDir },
    },
    directory,
    userMessageSeq,
    dryRun,
    ...(overrides.signal ? { signal: overrides.signal } : {}),
  });

  it('restores files before a delivered prompt: dry run, real rewind, then a verifying dry run, in one resumed session', async () => {
    const fake = primeSdkQuery(claudeRewind());

    const result = await restore(1, false);

    expect(result).toEqual({
      ok: true,
      restorable: true,
      restored: true,
      filesChanged: ['/repo/src/parser.ts', '/repo/src/lexer.ts'],
      insertions: 12,
      deletions: 4,
    });
    expect(sdkQuery).toHaveBeenCalledTimes(1);
    const { options } = sdkQuery.mock.calls[0]![0] as { options: Record<string, any> };
    expect(options).toMatchObject({
      resume: CLAUDE_SESSION_ID,
      cwd: directory,
      enableFileCheckpointing: true,
      settingSources: [],
      strictMcpConfig: true,
      pathToClaudeCodeExecutable: claudeExecutable,
    });
    expect(options.env.CLAUDE_CONFIG_DIR).toBe(configDir);
    expect(fake.rewindFiles.mock.calls).toEqual([
      ['u-prompt-1', { dryRun: true }],
      ['u-prompt-1', undefined],
      ['u-prompt-1', { dryRun: true }],
    ]);
    expect(fake.close).toHaveBeenCalled();
  });

  it('reports a partial restore as restore_failed naming the files Claude could not restore', async () => {
    const fake = primeSdkQuery(claudeRewind(['/repo/src/lexer.ts']));

    const result = await restore(1, false);

    expect(result).toMatchObject({ ok: false, errorCode: 'restore_failed' });
    expect(result.ok === false && result.errorMessage).toContain('/repo/src/lexer.ts');
    expect(fake.close).toHaveBeenCalled();
  });

  it('uses the default Claude home and its project path when the session recorded no config dir', async () => {
    env.patch({ HOME: homeDir });
    const defaultConfigDir = join(homeDir, '.claude');
    const defaultTranscript = join(getProjectPath(directory, defaultConfigDir), `${CLAUDE_SESSION_ID}.jsonl`);
    await mkdir(join(defaultTranscript, '..'), { recursive: true });
    await writeFile(defaultTranscript, `${JSON.stringify(userPrompt('u-prompt-1', 'Refactor the parser', { cwd: directory }))}\n`);
    const fake = primeSdkQuery(async () => DRY_RUN_RESULT);

    const result = await restore(1, true, {
      metadata: {
        path: directory,
        flavor: 'claude',
        claudeSessionId: CLAUDE_SESSION_ID,
        // Reported under another config dir than the restore resumes: not trusted.
        claudeTranscriptPath: transcriptPath,
      },
    });

    expect(result).toMatchObject({ ok: true, restorable: true, restored: false });
    const { options } = sdkQuery.mock.calls[0]![0] as { options: Record<string, any> };
    expect(options.env.CLAUDE_CONFIG_DIR).toBe(defaultConfigDir);
    expect(fake.rewindFiles.mock.calls).toEqual([['u-prompt-1', { dryRun: true }]]);
  });

  it('reports what a dry run would change without rewinding', async () => {
    const fake = primeSdkQuery(async () => DRY_RUN_RESULT);

    const result = await restore(4, true);

    expect(result).toMatchObject({ ok: true, restorable: true, restored: false, filesChanged: DRY_RUN_RESULT.filesChanged });
    expect(fake.rewindFiles.mock.calls).toEqual([['u-typed', { dryRun: true }]]);
  });

  it.each([5, 6])('maps each message of a batched prompt (seq %i) to that prompt', async (seq) => {
    const fake = primeSdkQuery(async () => DRY_RUN_RESULT);

    await expect(restore(seq, true)).resolves.toMatchObject({ ok: true, restorable: true });
    expect(fake.rewindFiles.mock.calls).toEqual([['u-batch', { dryRun: true }]]);
  });

  it.each([
    { seq: 8, case: 'a steer whose next Claude user row is a tool result' },
    { seq: 10, case: 'a steer whose text also appears in the next prompt' },
    { seq: 13, case: 'a marker whose prompt text is a different message' },
    { seq: 15, case: 'a steer followed by a prompt typed in the terminal that starts with its text' },
    { seq: 17, case: 'a message from another Agent that a later replay seed quotes' },
    { seq: 22, case: 'a marker whose prompt only begins with the message' },
    { seq: 26, case: 'a prompt Claude ran outside the session\'s working directory' },
    { seq: 28, case: 'a message with no marker after it' },
    { seq: 3, case: 'an agent row' },
    { seq: 99, case: 'a message that does not exist' },
  ])('does not restore $case', async ({ seq }) => {
    const result = await restore(seq, false);

    expect(result).toMatchObject({ ok: true, restorable: false, reasonCode: 'no_checkpoint' });
    expect(sdkQuery).not.toHaveBeenCalled();
  });

  it.each([
    { seq: 11, uuid: 'u-ok-go', case: 'the later prompt of an overlapping steer' },
    { seq: 20, uuid: 'u-seeded', case: 'the message a replay seed precedes' },
    { seq: 24, uuid: 'u-with-context', case: 'a prompt carrying Happier\'s provider-only context' },
  ])('maps $case to its own checkpoint', async ({ seq, uuid }) => {
    const fake = primeSdkQuery(async () => DRY_RUN_RESULT);

    await expect(restore(seq, true)).resolves.toMatchObject({ ok: true, restorable: true });
    expect(fake.rewindFiles.mock.calls).toEqual([[uuid, { dryRun: true }]]);
  });

  it('reports no checkpoint without touching files when Claude has none for the prompt (e.g. before a compaction)', async () => {
    const fake = primeSdkQuery(async () => ({ canRewind: false, error: 'No file checkpoint found for this message.' }));

    const result = await restore(1, false);

    expect(result).toEqual({
      ok: true,
      restorable: false,
      reasonCode: 'no_checkpoint',
      reason: 'No file checkpoint found for this message.',
    });
    expect(fake.rewindFiles.mock.calls).toEqual([['u-prompt-1', { dryRun: true }]]);
    expect(fake.close).toHaveBeenCalled();
  });

  it('returns restore_failed with Claude\'s message when the real rewind fails', async () => {
    const fake = primeSdkQuery(async (_id, options) => {
      if (options?.dryRun) return DRY_RUN_RESULT;
      throw new Error('Claude Code returned an error result: Failed to rewind: No files were restored');
    });

    const result = await restore(1, false);

    expect(result).toEqual({
      ok: false,
      errorCode: 'restore_failed',
      errorMessage: 'Claude Code returned an error result: Failed to rewind: No files were restored',
    });
    expect(fake.close).toHaveBeenCalled();
  });

  it('stops before the real rewind when the caller cancels after the dry run', async () => {
    const controller = new AbortController();
    const fake = primeSdkQuery(async (_id, options) => {
      if (options?.dryRun) controller.abort(new Error('RPC request cancelled by caller'));
      return DRY_RUN_RESULT;
    });

    await expect(restore(1, false, { signal: controller.signal })).rejects.toThrow(/cancelled/);
    expect(fake.rewindFiles.mock.calls).toEqual([['u-prompt-1', { dryRun: true }]]);
    expect(fake.close).toHaveBeenCalled();
  });

  it('settles and closes the resumed Claude when the caller cancels while Claude does not answer', async () => {
    const controller = new AbortController();
    const fake = primeSdkQuery(() => new Promise<RewindFilesResult>(() => {}));

    const pending = restore(1, false, { signal: controller.signal });
    await vi.waitFor(() => expect(fake.rewindFiles).toHaveBeenCalled());
    controller.abort(new Error('RPC request cancelled by caller'));

    await expect(pending).rejects.toThrow(/cancelled/);
    const { options } = sdkQuery.mock.calls[0]![0] as { options: { abortController?: AbortController } };
    expect(options.abortController?.signal.aborted).toBe(true);
    expect(fake.close).toHaveBeenCalled();
  });
});

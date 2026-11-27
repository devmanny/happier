import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import type { TranscriptRow } from '@/api/session/fetchEncryptedTranscriptWindow';
import type { Credentials } from '@/persistence';
import { createEnvKeyScope } from '@/testkit/env/envScope';
import { createTempDir, removeTempDir } from '@/testkit/fs/tempDir';

import { waitForClosed } from '../preflight/claudeCatalogProcessFixture.testkit';

/**
 * The restore against the real Agent SDK `query()` and its external Claude Code process boundary
 * (a fake executable speaking the SDK control protocol). Only the server's messages listing is
 * mocked. This is where the environment and flags the SDK derives for the child are observable.
 */
const fetchEncryptedTranscriptPageAfterSeq = vi.hoisted(() => vi.fn());

vi.mock('@/api/session/fetchEncryptedTranscriptWindow', async (importOriginal) => ({
  ...await importOriginal<typeof import('@/api/session/fetchEncryptedTranscriptWindow')>(),
  fetchEncryptedTranscriptPageAfterSeq,
}));

import { restoreClaudeSessionFiles } from './restoreClaudeSessionFiles';

const CLAUDE_SESSION_ID = '5d1e2f3a-bbbb-4ccc-8ddd-eeeeeeeeeeee';
const credentials = { token: 'token-1', encryption: { type: 'legacy', secret: new Uint8Array(32).fill(7) } } as Credentials;

/**
 * Claude Code 2.1.326's `rewind_files` control handler, reduced to its observable contract: SDK
 * checkpointing is gated on `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING`, a dry run lists what
 * differs from the checkpoint, and a real rewind answers `{ canRewind: true }`.
 */
const fakeClaudeCode = String.raw`
const fs = require('node:fs');
const readline = require('node:readline');
const log = (event) => fs.appendFileSync(process.env.HAPPIER_E2E_FAKE_CLAUDE_LOG, JSON.stringify(event) + '\n');
log({ type: 'spawn', argv: process.argv.slice(2), configDir: process.env.CLAUDE_CONFIG_DIR,
  checkpointing: process.env.CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING ?? null,
  resumeInterruptedTurn: process.env.CLAUDE_CODE_RESUME_INTERRUPTED_TURN ?? null });
process.on('SIGTERM', () => process.exit(0));
process.on('exit', () => log({ type: 'closed' }));
let rewound = false;
const reply = (requestId, response) => process.stdout.write(JSON.stringify({ type: 'control_response',
  response: { subtype: 'success', request_id: requestId, response } }) + '\n');
const input = readline.createInterface({ input: process.stdin });
input.on('close', () => process.exit(0));
input.on('line', (line) => {
  const message = JSON.parse(line);
  if (message.type !== 'control_request') return log({ type: message.type });
  const request = message.request;
  log({ type: 'control_request', subtype: request.subtype, id: request.user_message_id, dryRun: request.dry_run ?? null });
  if (request.subtype === 'initialize') return reply(message.request_id, { commands: [], models: [], agents: [] });
  if (request.subtype !== 'rewind_files') return reply(message.request_id, {});
  if (process.env.CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING !== 'true') {
    return reply(message.request_id, { canRewind: false, error: 'File rewinding is not enabled.' });
  }
  if (request.dry_run) {
    return reply(message.request_id, rewound
      ? { canRewind: true, filesChanged: [], insertions: 0, deletions: 0 }
      : { canRewind: true, filesChanged: ['src/parser.ts'], insertions: 3, deletions: 1 });
  }
  rewound = true;
  return reply(message.request_id, { canRewind: true, skippedLinks: 0 });
});
`;

function plainRow(seq: number, localId: string, body: unknown): TranscriptRow {
  return { seq, createdAt: 1_700_000_000_000 + seq, localId, content: { t: 'plain', v: body } as TranscriptRow['content'] };
}

describe('restoreClaudeSessionFiles through the Agent SDK process boundary', () => {
  const env = createEnvKeyScope(['HAPPIER_CLAUDE_PATH', 'HAPPIER_E2E_FAKE_CLAUDE_LOG', 'CLAUDE_CODE_RESUME_INTERRUPTED_TURN']);
  let root = '';

  beforeEach(async () => {
    root = await createTempDir('happier-claude-restore-process-');
    fetchEncryptedTranscriptPageAfterSeq.mockReset();
  });

  afterEach(async () => {
    env.restore();
    await removeTempDir(root);
  });

  it('resumes Claude with checkpointing enabled and no turn re-run, then restores and verifies', async () => {
    const configDir = join(root, 'claude-config');
    const directory = join(root, 'repo');
    const transcriptPath = join(configDir, 'projects', '-repo', `${CLAUDE_SESSION_ID}.jsonl`);
    const executable = join(root, 'claude.js');
    const logPath = join(root, 'claude-process.jsonl');
    await mkdir(join(configDir, 'projects', '-repo'), { recursive: true });
    await mkdir(directory, { recursive: true });
    await writeFile(transcriptPath, `${JSON.stringify({
      type: 'user',
      uuid: 'u-parser',
      isSidechain: false,
      cwd: directory,
      message: { role: 'user', content: 'Refactor the parser' },
    })}\n`);
    await writeFile(executable, fakeClaudeCode);
    env.patch({
      HAPPIER_CLAUDE_PATH: executable,
      HAPPIER_E2E_FAKE_CLAUDE_LOG: logPath,
      // A host directive asking a resumed Claude to re-run an interrupted turn (a model call).
      CLAUDE_CODE_RESUME_INTERRUPTED_TURN: '1',
    });
    fetchEncryptedTranscriptPageAfterSeq.mockImplementation(async (params: { afterSeq: number }) => [
      plainRow(1, 'local-1', { role: 'user', content: { type: 'text', text: 'Refactor the parser' } }),
      plainRow(2, 'claude-jsonl:main:user:u-parser', { role: 'agent', content: { type: 'output', data: { type: 'progress' } } }),
    ].filter((row) => row.seq > params.afterSeq));

    const result = await restoreClaudeSessionFiles({
      credentials,
      sessionId: 'sess_parent',
      rawSession: { encryptionMode: 'plain' },
      metadata: {
        path: directory,
        flavor: 'claude',
        claudeSessionId: CLAUDE_SESSION_ID,
        claudeTranscriptPath: transcriptPath,
        nativeAgentEnvironmentV1: { CLAUDE_CONFIG_DIR: configDir },
      },
      directory,
      userMessageSeq: 1,
      dryRun: false,
    });

    expect(result).toEqual({
      ok: true,
      restorable: true,
      restored: true,
      filesChanged: ['src/parser.ts'],
      insertions: 3,
      deletions: 1,
    });
    const events = await waitForClosed(logPath);
    const spawn = events.find((event) => event.type === 'spawn') as Record<string, any>;
    expect(spawn).toMatchObject({ configDir, checkpointing: 'true', resumeInterruptedTurn: null });
    expect(spawn.argv).toEqual(expect.arrayContaining(['--resume', CLAUDE_SESSION_ID, '--strict-mcp-config']));
    expect(events.filter((event) => event.subtype === 'rewind_files')).toEqual([
      { type: 'control_request', subtype: 'rewind_files', id: 'u-parser', dryRun: true },
      { type: 'control_request', subtype: 'rewind_files', id: 'u-parser', dryRun: null },
      { type: 'control_request', subtype: 'rewind_files', id: 'u-parser', dryRun: true },
    ]);
    expect(events.some((event) => event.type === 'user')).toBe(false);
  });
});

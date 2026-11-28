import { mkdir, readdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { getProjectPath } from '@/backends/claude/utils/path';
import type { Credentials } from '@/persistence';
import type { FetchEncryptedTranscriptMessagesPageResult } from '@/session/replay/fetchEncryptedTranscriptMessages';
import { createEnvKeyScope } from '@/testkit/env/envScope';
import { createTempDir, removeTempDir } from '@/testkit/fs/tempDir';

/**
 * Boundary: the server's `GET /v1/sessions/:id/messages` page client. The seq -> Claude message
 * mapping, the real transcript read and the Agent SDK's own `forkSession` stay real underneath it.
 */
const fetchEncryptedTranscriptMessagesPage = vi.hoisted(() => vi.fn());

vi.mock('@/session/replay/fetchEncryptedTranscriptMessages', async (importOriginal) => ({
  ...await importOriginal<typeof import('@/session/replay/fetchEncryptedTranscriptMessages')>(),
  fetchEncryptedTranscriptMessagesPage,
}));

import { claudeProviderNativeForkHandler } from './claudeProviderNativeForkHandler';

const PARENT_CLAUDE_SESSION_ID = '7b1f0c2e-1111-4222-8333-944445555666';
const U1 = '11111111-1111-4111-8111-111111111111';
const A1 = '22222222-2222-4222-8222-222222222222';
const U2 = '33333333-3333-4333-8333-333333333333';
const A2 = '44444444-4444-4444-8444-444444444444';
const OLDER_CONVERSATION_ROW = '55555555-5555-4555-8555-555555555555';
const credentials = { token: 'token-1', encryption: { type: 'legacy', secret: new Uint8Array(32).fill(3) } } as Credentials;

type ServerRow = Readonly<{ seq: number; localId: string }>;

/**
 * - 1: a message from another Claude conversation of this session (before a `/clear`);
 * - 2: Happier prompt, echo suppressed -> marker 3; reply 4;
 * - 5: Happier prompt -> marker 6; reply 7; then a synthetic turn-diff row (8).
 */
const SERVER_ROWS: ServerRow[] = [
  { seq: 1, localId: `claude-jsonl:main:assistant:${OLDER_CONVERSATION_ROW}` },
  { seq: 2, localId: 'local-2' },
  { seq: 3, localId: `claude-jsonl:main:user:${U1}` },
  { seq: 4, localId: `claude-jsonl:main:assistant:${A1}` },
  { seq: 5, localId: 'local-5' },
  { seq: 6, localId: `claude-jsonl:main:user:${U2}` },
  { seq: 7, localId: `claude-jsonl:main:assistant:${A2}` },
  { seq: 8, localId: 'claude-jsonl:main:assistant:turn-diff-0a1b2c-assistant' },
];

/** The server answers `beforeSeq` pages newest window first, rows ascending within the page. */
function servePages(rows: readonly ServerRow[]): void {
  fetchEncryptedTranscriptMessagesPage.mockImplementation(async (params: { beforeSeq?: number; limit: number }) => {
    const older = rows.filter((row) => params.beforeSeq === undefined || row.seq < params.beforeSeq);
    const page = older.slice(-params.limit);
    const hasMore = older.length > page.length;
    return {
      messages: page.map((row) => ({ seq: row.seq, localId: row.localId, createdAt: 1_700_000_000_000 + row.seq })),
      hasMore,
      nextBeforeSeq: hasMore ? page[0]!.seq : null,
      nextAfterSeq: null,
    } satisfies FetchEncryptedTranscriptMessagesPageResult;
  });
}

function transcriptRows(directory: string): Record<string, unknown>[] {
  const base = { sessionId: PARENT_CLAUDE_SESSION_ID, cwd: directory, isSidechain: false };
  return [
    { type: 'user', uuid: U1, parentUuid: null, timestamp: '2026-11-26T10:00:00.000Z', message: { role: 'user', content: 'first ask' }, ...base },
    { type: 'assistant', uuid: A1, parentUuid: U1, timestamp: '2026-11-26T10:00:05.000Z', message: { role: 'assistant', content: [{ type: 'text', text: 'first answer' }] }, ...base },
    { type: 'user', uuid: U2, parentUuid: A1, timestamp: '2026-11-26T10:01:00.000Z', message: { role: 'user', content: 'second ask' }, ...base },
    { type: 'assistant', uuid: A2, parentUuid: U2, timestamp: '2026-11-26T10:01:05.000Z', message: { role: 'assistant', content: [{ type: 'text', text: 'second answer' }] }, ...base },
  ];
}

async function readJsonl(path: string): Promise<Record<string, unknown>[]> {
  return (await readFile(path, 'utf8')).split('\n').filter(Boolean).map((line) => JSON.parse(line) as Record<string, unknown>);
}

describe('claudeProviderNativeForkHandler', () => {
  let root: string;
  let directory: string;
  let configDir: string;
  let projectDir: string;
  const env = createEnvKeyScope(['HOME', 'CLAUDE_CONFIG_DIR']);

  beforeEach(async () => {
    root = await createTempDir('claude-native-fork-');
    directory = join(root, 'project');
    configDir = join(root, 'claude-home');
    await mkdir(directory, { recursive: true });
    projectDir = getProjectPath(directory, configDir);
    await mkdir(projectDir, { recursive: true });
    await writeFile(
      join(projectDir, `${PARENT_CLAUDE_SESSION_ID}.jsonl`),
      `${transcriptRows(directory).map((row) => JSON.stringify(row)).join('\n')}\n`,
    );
    servePages(SERVER_ROWS);
  });

  afterEach(async () => {
    fetchEncryptedTranscriptMessagesPage.mockReset();
    env.restore();
    await removeTempDir(root);
  });

  const fork = (cutoffSeqInclusive: number, metadata: Record<string, unknown> = {}) => claudeProviderNativeForkHandler({
    credentials,
    agentId: 'claude',
    parentSessionId: 'parent-happier-session',
    parentRawSession: {},
    parentMetadata: {
      claudeSessionId: PARENT_CLAUDE_SESSION_ID,
      nativeAgentEnvironmentV1: { CLAUDE_CONFIG_DIR: configDir },
      ...metadata,
    },
    directory,
    forkPoint: { type: 'seq', upToSeqInclusive: cutoffSeqInclusive + 1 },
    targetSeqInclusive: cutoffSeqInclusive + 1,
    cutoffSeqInclusive,
  });

  it('copies the Claude conversation up to the last Claude message at or before the cutoff', async () => {
    // Edit from Here on message 5: the branch keeps 1-4, so Claude keeps the first turn only.
    const result = await fork(4);

    expect(result).not.toBeNull();
    const childId = result!.vendorSessionId;
    expect(childId).not.toBe(PARENT_CLAUDE_SESSION_ID);
    const copied = await readJsonl(join(projectDir, `${childId}.jsonl`));
    expect(copied.filter((row) => row.type === 'user' || row.type === 'assistant').map((row) => row.forkedFrom))
      .toEqual([
        { sessionId: PARENT_CLAUDE_SESSION_ID, messageUuid: U1 },
        { sessionId: PARENT_CLAUDE_SESSION_ID, messageUuid: A1 },
      ]);
    expect(result!.spawn).toEqual({ resume: childId, environmentVariables: { CLAUDE_CONFIG_DIR: configDir } });
    expect(result!.metadata).toEqual({ claudeSessionId: childId });
    expect(result!.providerHint).toEqual({ providerId: 'claude', vendorSessionId: childId });
  });

  it('skips rows that are not Claude conversation messages when choosing the fork point', async () => {
    const result = await fork(8);

    const copied = await readJsonl(join(projectDir, `${result!.vendorSessionId}.jsonl`));
    expect(copied.filter((row) => row.type === 'assistant').map((row) => (row.forkedFrom as { messageUuid: string }).messageUuid))
      .toEqual([A1, A2]);
  });

  it('forks in the default Claude home, without pinning it on the child, when the parent used it', async () => {
    const homeDir = join(root, 'home');
    const defaultProjectDir = getProjectPath(directory, join(homeDir, '.claude'));
    await mkdir(defaultProjectDir, { recursive: true });
    await writeFile(
      join(defaultProjectDir, `${PARENT_CLAUDE_SESSION_ID}.jsonl`),
      `${transcriptRows(directory).map((row) => JSON.stringify(row)).join('\n')}\n`,
    );
    env.patch({ HOME: homeDir, CLAUDE_CONFIG_DIR: undefined });

    const result = await claudeProviderNativeForkHandler({
      credentials,
      agentId: 'claude',
      parentSessionId: 'parent-happier-session',
      parentRawSession: {},
      parentMetadata: { claudeSessionId: PARENT_CLAUDE_SESSION_ID },
      directory,
      forkPoint: { type: 'latest' },
      targetSeqInclusive: 8,
      cutoffSeqInclusive: 8,
    });

    expect(result!.spawn).toEqual({ resume: result!.vendorSessionId });
    await expect(readJsonl(join(defaultProjectDir, `${result!.vendorSessionId}.jsonl`))).resolves.not.toHaveLength(0);
  });

  it('leaves forks from an older Claude conversation of the session to replay', async () => {
    await expect(fork(1)).resolves.toBeNull();
    expect((await readdir(projectDir)).sort()).toEqual([`${PARENT_CLAUDE_SESSION_ID}.jsonl`]);
  });

  it('leaves sessions without a Claude conversation or with connected services to replay', async () => {
    await expect(fork(4, { claudeSessionId: undefined })).resolves.toBeNull();
    await expect(fork(4, {
      connectedServices: { v: 1, bindingsByServiceId: { anthropic: { source: 'connected', profileId: 'work' } } },
    })).resolves.toBeNull();
    expect((await readdir(projectDir)).sort()).toEqual([`${PARENT_CLAUDE_SESSION_ID}.jsonl`]);
  });
});

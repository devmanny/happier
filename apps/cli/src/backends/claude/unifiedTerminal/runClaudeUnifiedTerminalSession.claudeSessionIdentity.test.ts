import { appendFile, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { afterEach, describe, expect, it, vi } from 'vitest';

import { MessageQueue2 } from '@/agent/runtime/modeMessageQueue';
import type { SessionClientPort } from '@/api/session/sessionClientPort';
import type { Metadata } from '@/api/types';
import type {
  TerminalAttachmentId,
  TerminalHostAdapter,
  TerminalHostHandle,
} from '@/integrations/terminalHost/_types';
import type { TerminalAttachmentInfo } from '@/terminal/attachment/terminalAttachmentInfo';
import type { EnhancedMode } from '../loop';
import { Session } from '../session';
import type { RawJSONLines } from '../types';
import { getProjectPath } from '../utils/path';
import type { SessionHookData } from '../utils/startHookServer';
import { runClaudeUnifiedTerminalSession } from './runClaudeUnifiedTerminalSession';

const interactiveClaudeScreen = [
  'Some previous Claude output',
  '',
  'What would you like to work on?',
  '> ',
].join('\n');

async function waitMs(ms: number): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitUntil(predicate: () => boolean, timeoutMs = 3_000): Promise<void> {
  const startedAt = Date.now();
  while (!predicate()) {
    if (Date.now() - startedAt > timeoutMs) {
      throw new Error('Timed out waiting for condition');
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

/** The session server boundary: metadata lives behind `updateMetadata`, everything else is inert. */
function createMetadataClient(happySessionId: string, seed: Partial<Metadata> = {}): Readonly<{
  client: SessionClientPort;
  readMetadata: () => Metadata;
}> {
  let metadata: Metadata = {
    path: '/tmp',
    host: 'host',
    homeDir: '/home',
    happyHomeDir: '/home/.happier',
    happyLibDir: '/home/.happier/lib',
    happyToolsDir: '/home/.happier/tools',
    startedBy: 'daemon',
    ...seed,
  };
  const client: SessionClientPort = {
    sessionId: happySessionId,
    rpcHandlerManager: {
      registerHandler: vi.fn(),
      invokeLocal: vi.fn(async () => ({})),
    },
    sendSessionEvent: vi.fn(),
    sendClaudeSessionMessage: vi.fn(),
    sendAgentMessage: vi.fn(),
    sendAgentMessageCommitted: vi.fn(async () => {}),
    keepAlive: vi.fn(),
    getMetadataSnapshot: () => metadata,
    waitForMetadataUpdate: vi.fn(async () => false),
    waitForPendingEligibilityUpdate: vi.fn(async () => false),
    popPendingMessage: vi.fn(async () => false),
    peekPendingMessageQueueV2Count: vi.fn(async () => 0),
    discardPendingMessageQueueV2All: vi.fn(async () => 0),
    discardCommittedMessageLocalIds: vi.fn(async () => 0),
    updateMetadata: vi.fn(async (updater: (current: Metadata) => Metadata) => {
      metadata = updater(metadata);
    }),
    updateAgentStateRequestSettlement: vi.fn(async () => {}),
    updateAgentState: vi.fn(),
    sendSessionDeath: vi.fn(),
    flush: vi.fn(async () => {}),
    close: vi.fn(async () => {}),
    on: vi.fn(),
    off: vi.fn(),
  };
  return { client, readMetadata: () => metadata };
}

function createClaudeSession(client: SessionClientPort, workspaceDir: string, claudeSessionId: string | null = null): Session {
  return new Session({
    client,
    path: workspaceDir,
    logPath: join(workspaceDir, 'log'),
    sessionId: claudeSessionId,
    messageQueue: new MessageQueue2<EnhancedMode>(() => 'mode'),
    onModeChange: () => {},
    hookSettingsPath: join(workspaceDir, 'hooks.json'),
    startedBy: 'daemon',
  });
}

/** Wires the runner to the Claude identity owner exactly as the unified launcher does. */
function identityOwnerWiring(session: Session) {
  return {
    onSessionFound: (sessionId: string, data?: SessionHookData) => session.onSessionFound(sessionId, data),
    onTrustedMainTranscriptRow: (sessionId: string) => session.retryPendingSessionIdentityPublication(sessionId),
  };
}

function tmuxHandle(sessionName: string, attachmentId?: TerminalAttachmentId): TerminalHostHandle {
  return {
    ...(attachmentId ? { attachmentId } : {}),
    kind: 'tmux',
    sessionName,
    paneId: '%1',
    attachMetadata: {
      attachStrategy: 'terminal_host',
      topology: 'shared',
      locality: 'same_machine',
      liveProbe: 'required',
    },
  };
}


const adoptedPanePid = 4242;
const adoptedClaudePid = 4243;
const adoptedClaudeProcStart = 'Mon Nov 16 21:51:45 2026';

/** Claude's own process record for the pane's live Claude (launch-spec runner 4242 -> claude 4243). */
async function writeAdoptedClaudeProcessRecord(claudeConfigDir: string, workspaceDir: string, claudeSessionId: string): Promise<void> {
  await mkdir(join(claudeConfigDir, 'sessions'), { recursive: true });
  await writeFile(join(claudeConfigDir, 'sessions', `${adoptedClaudePid}.json`), JSON.stringify({
    pid: adoptedClaudePid,
    sessionId: claudeSessionId,
    cwd: workspaceDir,
    startedAt: Date.parse(`${adoptedClaudeProcStart} GMT`),
    procStart: adoptedClaudeProcStart,
    kind: 'interactive',
  }));
}

/** OS process boundary: the adopted pane's process tree and kernel start times. */
function createAdoptedClaudeProcessProbe(extra: readonly Readonly<{ pid: number; ppid: number }>[] = []) {
  return {
    listProcesses: vi.fn(async () => [
      { pid: 1, ppid: 0 },
      { pid: adoptedPanePid, ppid: 1 },
      { pid: adoptedClaudePid, ppid: adoptedPanePid },
      ...extra,
    ]),
    readProcessStartUtc: vi.fn(async (pid: number) => (
      pid === adoptedClaudePid || extra.some((entry) => entry.pid === pid) ? adoptedClaudeProcStart : null
    )),
  };
}

/** A live tmux host saved by the previous runner, adopted without relaunching Claude. */
function createAdoptedHost(happySessionId: string, sessionName: string) {
  const attachmentId = `attachment-${sessionName}` as TerminalAttachmentId;
  const existingHandle = tmuxHandle(sessionName, attachmentId);
  const existingAttachment: TerminalAttachmentInfo = {
    version: 2,
    attachmentId,
    sessionId: happySessionId,
    handle: existingHandle as TerminalHostHandle & Readonly<{ attachmentId: TerminalAttachmentId }>,
    terminal: { mode: 'tmux', tmux: { target: `${sessionName}:%1` } },
    updatedAt: 1,
  };
  const adapter: TerminalHostAdapter = {
    kind: 'tmux',
    createOrAttachHost: vi.fn(async () => {
      throw new Error('an attached live Claude must not be relaunched');
    }),
    adoptExistingHost: vi.fn(async () => existingHandle),
    injectUserPrompt: vi.fn(async () => ({ status: 'injected', at: Date.now(), bytesWritten: 0 }) as const),
    evaluateLiveness: vi.fn(async () => ({ paneAlive: true, panePid: adoptedPanePid, observedAt: Date.now() })),
    captureInputState: vi.fn(async () => ({
      stable: true,
      currentInput: interactiveClaudeScreen,
      observedAt: Date.now(),
    })),
    interruptTurn: vi.fn(async () => {}),
    dispose: vi.fn(async () => {}),
  };
  return {
    adapter,
    runnerOptions: {
      expectedExistingTerminalHostAttachmentId: attachmentId,
      readTerminalHostAttachmentInfo: async () => existingAttachment,
      persistTerminalHostAttachmentInfo: async () => {},
      resolveHostAdapter: async () => ({ status: 'resolved' as const, adapter, reason: 'test' }),
      buildSpawn: async () => ({ spawnArgv: ['/bin/claude'], spawnEnv: {} }),
      createSessionName: () => sessionName,
      subscribeClaudeSessionHooks: () => () => {},
      lifecycleCompletionQuiescenceMs: 0,
      dialogTurnEndScreenProbeDelaysMs: [],
    },
  };
}

function jsonlRow(row: Record<string, unknown>): string {
  return `${JSON.stringify(row)}\n`;
}

describe('runClaudeUnifiedTerminalSession Claude session identity publication', () => {
  const tempDirs: string[] = [];
  const previousClaudeConfigDir = process.env.CLAUDE_CONFIG_DIR;

  afterEach(async () => {
    if (previousClaudeConfigDir === undefined) delete process.env.CLAUDE_CONFIG_DIR;
    else process.env.CLAUDE_CONFIG_DIR = previousClaudeConfigDir;
    for (const dir of tempDirs.splice(0)) {
      await rm(dir, { recursive: true, force: true });
    }
  });

  it('publishes a fresh Claude id once its transcript materializes after the prompt hook already accepted the prompt', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'happier-claude-fresh-identity-'));
    tempDirs.push(dir);
    const workspaceDir = join(dir, 'workspace');
    await mkdir(workspaceDir, { recursive: true });
    const claudeConfigDir = join(dir, 'claude-config');
    const projectDir = getProjectPath(workspaceDir, claudeConfigDir);
    await mkdir(projectDir, { recursive: true });
    process.env.CLAUDE_CONFIG_DIR = claudeConfigDir;
    const claudeSessionId = '54f29255-5327-4b7f-9dd9-f7808755b43c';
    // Claude creates `<id>.jsonl` only when the first prompt is submitted, after SessionStart.
    const transcriptPath = join(projectDir, `${claudeSessionId}.jsonl`);

    const { client, readMetadata } = createMetadataClient('happy-fresh-identity');
    const session = createClaudeSession(client, workspaceDir);
    const prompt = 'Fresh conversation first prompt';
    const abortController = new AbortController();
    let subscribedHook: ((data: SessionHookData) => void) | undefined;
    let consumed = false;
    let transcriptWritten = false;
    const onPromptAcceptedByProvider = vi.fn();
    const handle = tmuxHandle('happier-claude-fresh-identity-test');
    const adapter: TerminalHostAdapter = {
      kind: 'tmux',
      createOrAttachHost: vi.fn(async () => {
        const hook = subscribedHook;
        if (!hook) throw new Error('provider launched before the hook subscription was installed');
        hook({
          hook_event_name: 'SessionStart',
          session_id: claudeSessionId,
          transcript_path: transcriptPath,
          source: 'startup',
        });
        return handle;
      }),
      injectUserPrompt: vi.fn(async (_handle, input) => {
        const hook = subscribedHook;
        if (!hook) throw new Error('Claude session hook subscription was not registered before injection');
        // The provider hook accepts the exact prompt before Claude writes its transcript row.
        hook({
          hook_event_name: 'UserPromptSubmit',
          session_id: claudeSessionId,
          transcript_path: transcriptPath,
          prompt_id: 'fresh-prompt-id',
          prompt: input.text,
        });
        await new Promise((resolve) => setTimeout(resolve, 50));
        await appendFile(transcriptPath, `${JSON.stringify({
          type: 'user',
          uuid: 'fresh-accepted-user-row',
          promptId: 'fresh-prompt-id',
          sessionId: claudeSessionId,
          timestamp: new Date().toISOString(),
          isSidechain: false,
          message: { role: 'user', content: input.text },
        })}\n`);
        transcriptWritten = true;
        return { status: 'injected', at: Date.now(), bytesWritten: input.text.length } as const;
      }),
      evaluateLiveness: vi.fn(async () => ({ paneAlive: true, observedAt: Date.now() })),
      captureInputState: vi.fn(async () => ({
        stable: true,
        currentInput: interactiveClaudeScreen,
        observedAt: Date.now(),
      })),
      interruptTurn: vi.fn(async () => {}),
      dispose: vi.fn(async () => {}),
    };

    const sessionPromise = runClaudeUnifiedTerminalSession({
      path: workspaceDir,
      happySessionId: 'happy-fresh-identity',
      sessionId: null,
      hookPluginDir: join(dir, 'owned-happier-hook-plugin'),
      signal: abortController.signal,
      nextMessage: async () => {
        if (consumed) return await new Promise(() => undefined);
        consumed = true;
        return {
          message: prompt,
          mode: { permissionMode: 'default', claudeUnifiedTerminalHost: 'tmux' },
          userMessageLocalIds: ['fresh-identity-local-id'],
        };
      },
      ...identityOwnerWiring(session),
      onPromptAcceptedByProvider,
      readTerminalHostAttachmentInfo: async () => null,
      persistTerminalHostAttachmentInfo: async () => {},
      resolveHostAdapter: async () => ({ status: 'resolved', adapter, reason: 'test' }),
      buildSpawn: async () => ({ spawnArgv: ['/bin/claude'], spawnEnv: {} }),
      createSessionName: () => 'happier-claude-fresh-identity-test',
      subscribeClaudeSessionHooks: (callback) => {
        subscribedHook = callback;
        return () => {
          subscribedHook = undefined;
        };
      },
      lifecycleCompletionQuiescenceMs: 0,
      dialogTurnEndScreenProbeDelaysMs: [],
    }).catch((error: unknown) => error);

    try {
      await waitUntil(() => transcriptWritten);
      await waitUntil(() => onPromptAcceptedByProvider.mock.calls.length === 1);
      // The SessionStart observation could not be proven: nothing is published yet.
      expect(readMetadata().claudeSessionId).toBeUndefined();

      await appendFile(transcriptPath, `${JSON.stringify({
        type: 'assistant',
        uuid: 'fresh-assistant-row',
        sessionId: claudeSessionId,
        timestamp: new Date().toISOString(),
        message: { role: 'assistant', content: [{ type: 'text', text: 'hello' }], stop_reason: 'end_turn' },
      })}\n`);

      await waitUntil(() => readMetadata().claudeSessionId === claudeSessionId);
      await session.drainCriticalMetadataWrites({ timeoutMs: 1_000 });
      expect(readMetadata()).toEqual(expect.objectContaining({
        claudeSessionId,
        claudeTranscriptPath: transcriptPath,
      }));
    } finally {
      abortController.abort();
      await sessionPromise;
      session.cleanup();
    }
  });

  it('recovers, publishes and follows the live Claude conversation when it adopts a host whose metadata lost the id', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'happier-claude-attached-identity-'));
    tempDirs.push(dir);
    const workspaceDir = join(dir, 'workspace');
    await mkdir(workspaceDir, { recursive: true });
    const claudeConfigDir = join(dir, 'claude-config');
    const projectDir = getProjectPath(workspaceDir, claudeConfigDir);
    await mkdir(projectDir, { recursive: true });
    process.env.CLAUDE_CONFIG_DIR = claudeConfigDir;
    const claudeSessionId = '54f29255-5327-4b7f-9dd9-f7808755b43c';
    const transcriptPath = join(projectDir, `${claudeSessionId}.jsonl`);
    await writeFile(transcriptPath, [
      { type: 'user', uuid: 'earlier-user-row', sessionId: claudeSessionId, timestamp: '2026-11-16T21:51:46.000Z', isSidechain: false, message: { role: 'user', content: 'hola' } },
      { type: 'assistant', uuid: 'earlier-assistant-row', sessionId: claudeSessionId, timestamp: '2026-11-16T21:51:50.000Z', message: { role: 'assistant', content: [{ type: 'text', text: 'hola!' }], stop_reason: 'end_turn' } },
    ].map(jsonlRow).join(''));
    await writeAdoptedClaudeProcessRecord(claudeConfigDir, workspaceDir, claudeSessionId);
    // An unrelated Claude in the same config dir and cwd, outside the pane's process tree, must not be picked.
    await writeFile(join(claudeConfigDir, 'sessions', '9999.json'), JSON.stringify({
      pid: 9999,
      sessionId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      cwd: workspaceDir,
      procStart: adoptedClaudeProcStart,
    }));

    const happySessionId = 'happy-attached-identity';
    const host = createAdoptedHost(happySessionId, 'happier-claude-attached-identity-test');
    const { client, readMetadata } = createMetadataClient(happySessionId);
    const session = createClaudeSession(client, workspaceDir);
    const abortController = new AbortController();
    const onMessage = vi.fn<(message: RawJSONLines) => void>();

    const sessionPromise = runClaudeUnifiedTerminalSession({
      path: workspaceDir,
      happySessionId,
      sessionId: null,
      transcriptPath: null,
      initialMode: { permissionMode: 'default', claudeUnifiedTerminalHost: 'tmux' },
      hookPluginDir: join(dir, 'owned-happier-hook-plugin'),
      signal: abortController.signal,
      nextMessage: async () => await new Promise(() => undefined),
      ...identityOwnerWiring(session),
      onMessage,
      // The earlier turn already reached the app before the old runner died.
      loadCommittedClaudeJsonlMessageBaseline: async () => ({
        keys: new Set(['main:user:earlier-user-row', 'main:assistant:earlier-assistant-row']),
        complete: true,
        oldestCoveredAtMs: null,
      }),
      claudeProcessProbe: createAdoptedClaudeProcessProbe([{ pid: 9999, ppid: 1 }]),
      ...host.runnerOptions,
    }).catch((error: unknown) => error);

    try {
      await waitUntil(() => readMetadata().claudeSessionId === claudeSessionId);
      await session.drainCriticalMetadataWrites({ timeoutMs: 1_000 });
      expect(readMetadata()).toEqual(expect.objectContaining({
        claudeSessionId,
        claudeTranscriptPath: transcriptPath,
      }));
      expect(host.adapter.createOrAttachHost).not.toHaveBeenCalled();

      // A reply Claude writes after the attach reaches the app.
      await appendFile(transcriptPath, jsonlRow({
        type: 'assistant',
        uuid: 'post-attach-assistant-row',
        sessionId: claudeSessionId,
        timestamp: new Date().toISOString(),
        message: { role: 'assistant', content: [{ type: 'text', text: 'still here' }], stop_reason: 'end_turn' },
      }));
      await waitUntil(() => onMessage.mock.calls.some(([message]) => message.uuid === 'post-attach-assistant-row'));
      // Already-committed history is not sent again.
      expect(onMessage.mock.calls.map(([message]) => message.uuid)).toEqual(['post-attach-assistant-row']);
    } finally {
      abortController.abort();
      await sessionPromise;
      session.cleanup();
    }
  });

  it('switches to the conversation Claude moved to when it adopts a host whose metadata still holds the previous id', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'happier-claude-attached-switched-identity-'));
    tempDirs.push(dir);
    const workspaceDir = join(dir, 'workspace');
    await mkdir(workspaceDir, { recursive: true });
    const claudeConfigDir = join(dir, 'claude-config');
    const projectDir = getProjectPath(workspaceDir, claudeConfigDir);
    await mkdir(projectDir, { recursive: true });
    process.env.CLAUDE_CONFIG_DIR = claudeConfigDir;
    const previousSessionId = 'a022b1b9-0000-4000-8000-000000000001';
    const previousTranscriptPath = join(projectDir, `${previousSessionId}.jsonl`);
    await writeFile(previousTranscriptPath, jsonlRow({
      type: 'assistant', uuid: 'previous-assistant-row', sessionId: previousSessionId,
      timestamp: '2026-11-16T21:40:00.000Z',
      message: { role: 'assistant', content: [{ type: 'text', text: 'before /clear' }], stop_reason: 'end_turn' },
    }));
    // /clear moved the live Claude to a new conversation whose file does not exist until its first prompt.
    const currentSessionId = 'b33f0000-0000-4000-8000-000000000002';
    const currentTranscriptPath = join(projectDir, `${currentSessionId}.jsonl`);
    await writeAdoptedClaudeProcessRecord(claudeConfigDir, workspaceDir, currentSessionId);

    const happySessionId = 'happy-attached-switched-identity';
    const host = createAdoptedHost(happySessionId, 'happier-claude-attached-switched-identity-test');
    const { client, readMetadata } = createMetadataClient(happySessionId, {
      claudeSessionId: previousSessionId,
      claudeTranscriptPath: previousTranscriptPath,
    });
    const session = createClaudeSession(client, workspaceDir, previousSessionId);
    const abortController = new AbortController();
    const onMessage = vi.fn<(message: RawJSONLines) => void>();

    const sessionPromise = runClaudeUnifiedTerminalSession({
      path: workspaceDir,
      happySessionId,
      sessionId: previousSessionId,
      transcriptPath: previousTranscriptPath,
      initialMode: { permissionMode: 'default', claudeUnifiedTerminalHost: 'tmux' },
      hookPluginDir: join(dir, 'owned-happier-hook-plugin'),
      signal: abortController.signal,
      nextMessage: async () => await new Promise(() => undefined),
      ...identityOwnerWiring(session),
      onMessage,
      loadCommittedClaudeJsonlMessageBaseline: async () => ({
        keys: new Set(['main:assistant:previous-assistant-row']),
        complete: true,
        oldestCoveredAtMs: null,
      }),
      claudeProcessProbe: createAdoptedClaudeProcessProbe(),
      ...host.runnerOptions,
    }).catch((error: unknown) => error);

    try {
      await waitUntil(() => (host.adapter.evaluateLiveness as ReturnType<typeof vi.fn>).mock.calls.length > 0);
      await waitMs(100);
      await session.drainCriticalMetadataWrites({ timeoutMs: 1_000 });
      // Unproven until Claude writes it: the previous id stays published meanwhile.
      expect(readMetadata().claudeSessionId).toBe(previousSessionId);

      await writeFile(currentTranscriptPath, [
        { type: 'user', uuid: 'current-user-row', sessionId: currentSessionId, timestamp: new Date().toISOString(), isSidechain: false, message: { role: 'user', content: 'after clear' } },
        { type: 'assistant', uuid: 'current-assistant-row', sessionId: currentSessionId, timestamp: new Date().toISOString(), message: { role: 'assistant', content: [{ type: 'text', text: 'fresh' }], stop_reason: 'end_turn' } },
      ].map(jsonlRow).join(''));

      await waitUntil(() => readMetadata().claudeSessionId === currentSessionId);
      await session.drainCriticalMetadataWrites({ timeoutMs: 1_000 });
      expect(readMetadata()).toEqual(expect.objectContaining({
        claudeSessionId: currentSessionId,
        claudeTranscriptPath: currentTranscriptPath,
      }));
      await waitUntil(() => onMessage.mock.calls.some(([message]) => message.uuid === 'current-assistant-row'));
    } finally {
      abortController.abort();
      await sessionPromise;
      session.cleanup();
    }
  });

  it('publishes the recovered id when the adopted Claude finishes a line it was writing during adoption', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'happier-claude-attached-partial-identity-'));
    tempDirs.push(dir);
    const workspaceDir = join(dir, 'workspace');
    await mkdir(workspaceDir, { recursive: true });
    const claudeConfigDir = join(dir, 'claude-config');
    const projectDir = getProjectPath(workspaceDir, claudeConfigDir);
    await mkdir(projectDir, { recursive: true });
    process.env.CLAUDE_CONFIG_DIR = claudeConfigDir;
    const claudeSessionId = '54f29255-5327-4b7f-9dd9-f7808755b43d';
    const transcriptPath = join(projectDir, `${claudeSessionId}.jsonl`);
    const writingRow = jsonlRow({
      type: 'assistant', uuid: 'reply-written-across-adoption', sessionId: claudeSessionId,
      timestamp: new Date().toISOString(),
      message: { role: 'assistant', content: [{ type: 'text', text: 'last reply of the turn' }], stop_reason: 'end_turn' },
    });
    const splitAt = Math.floor(writingRow.length / 2);
    // The file holds only the row Claude is still writing: no complete identifying record yet.
    await writeFile(transcriptPath, writingRow.slice(0, splitAt));
    await writeAdoptedClaudeProcessRecord(claudeConfigDir, workspaceDir, claudeSessionId);

    const happySessionId = 'happy-attached-partial-identity';
    const host = createAdoptedHost(happySessionId, 'happier-claude-attached-partial-identity-test');
    const { client, readMetadata } = createMetadataClient(happySessionId);
    const session = createClaudeSession(client, workspaceDir);
    const abortController = new AbortController();
    const onMessage = vi.fn<(message: RawJSONLines) => void>();
    let pendingBeforeCompletion: string | undefined | null = null;

    const sessionPromise = runClaudeUnifiedTerminalSession({
      path: workspaceDir,
      happySessionId,
      sessionId: null,
      transcriptPath: null,
      initialMode: { permissionMode: 'default', claudeUnifiedTerminalHost: 'tmux' },
      hookPluginDir: join(dir, 'owned-happier-hook-plugin'),
      signal: abortController.signal,
      nextMessage: async () => await new Promise(() => undefined),
      ...identityOwnerWiring(session),
      onMessage,
      loadCommittedClaudeJsonlMessageBaseline: async () => {
        // The recovered id's first proof has run against the half-written line; Claude then
        // finishes the last row of its turn and writes nothing else.
        await session.drainCriticalMetadataWrites({ timeoutMs: 1_000 });
        pendingBeforeCompletion = readMetadata().claudeSessionId;
        await appendFile(transcriptPath, writingRow.slice(splitAt));
        return { keys: new Set<string>(), complete: true, oldestCoveredAtMs: null };
      },
      claudeProcessProbe: createAdoptedClaudeProcessProbe(),
      ...host.runnerOptions,
    }).catch((error: unknown) => error);

    try {
      await waitUntil(() => pendingBeforeCompletion !== null);
      expect(pendingBeforeCompletion).toBeUndefined();
      await waitUntil(() => readMetadata().claudeSessionId === claudeSessionId);
      await session.drainCriticalMetadataWrites({ timeoutMs: 1_000 });
      expect(readMetadata().claudeTranscriptPath).toBe(transcriptPath);
      await waitUntil(() => onMessage.mock.calls.some(([message]) => message.uuid === 'reply-written-across-adoption'));
    } finally {
      abortController.abort();
      await sessionPromise;
      session.cleanup();
    }
  });
});

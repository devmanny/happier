import { describe, expect, it, vi } from 'vitest';

import type {
  TerminalAttachmentId,
  TerminalHostAdapter,
  TerminalHostHandle,
} from '@/integrations/terminalHost/_types';
import type { TerminalInputInjectionV1, TerminalPromptInput } from '@/agent/runtime/terminal/TerminalInputInjectionV1';

import { runClaudeUnifiedTerminalSession } from './runClaudeUnifiedTerminalSession';
import type { ClaudeUnifiedRuntimeControlApplyResult, ClaudeUnifiedRuntimeControlBridge } from './runtimeControlIntegration';

const handle: TerminalHostHandle = {
  attachmentId: 'attachment-blocked-apply-clear' as TerminalAttachmentId,
  kind: 'tmux',
  sessionName: 'happier-blocked-apply-clear',
  paneId: '%1',
  attachMetadata: {
    attachStrategy: 'terminal_host',
    topology: 'shared',
    locality: 'same_machine',
    liveProbe: 'required',
  },
};

function createAdapter(): TerminalHostAdapter {
  return {
    kind: 'tmux',
    createOrAttachHost: vi.fn(async () => handle),
    injectUserPrompt: vi.fn(async () => ({ status: 'injected' as const, at: Date.now(), bytesWritten: 0 })),
    interruptTurn: vi.fn(async () => undefined),
    evaluateLiveness: vi.fn(async () => ({ paneAlive: true, observedAt: Date.now() })),
    dispose: vi.fn(async () => undefined),
  };
}

function createBridge(applies: ClaudeUnifiedRuntimeControlApplyResult[]): ClaudeUnifiedRuntimeControlBridge {
  return {
    applyBeforePrompt: vi.fn(async () => applies.shift() ?? { promptMayProceed: true, attempted: false }),
    applyOutOfBand: vi.fn(async () => ({ promptMayProceed: true, attempted: false })),
    applyPermissionModeForInFlightSteer: vi.fn(async () => ({ status: 'unsupported' }) as never),
    reconcileFromPromptSubmitMetadata: vi.fn(),
    reconcileFromStatusline: vi.fn(),
    isControlInFlight: vi.fn(() => false),
    ownsDialog: vi.fn(() => false),
    whenControlIdle: vi.fn(async () => undefined),
    dispose: vi.fn(async () => undefined),
  };
}

/** Runs the runner with the given before-prompt applies and writes `prompts` through its gated injection. */
async function injectThroughRuntimeControlGate(params: Readonly<{
  applies: ClaudeUnifiedRuntimeControlApplyResult[];
  prompts: number;
}>): Promise<Readonly<{ onBlockedApplyClear: ReturnType<typeof vi.fn>; statuses: string[] }>> {
  const abortController = new AbortController();
  const onBlockedApplyClear = vi.fn();
  const statuses: string[] = [];
  const adapter = createAdapter();
  await runClaudeUnifiedTerminalSession({
    path: '/workspace/project',
    happySessionId: 'happy-blocked-apply-clear',
    sessionId: 'claude-blocked-apply-clear',
    initialMode: { permissionMode: 'default', claudeUnifiedTerminalHost: 'tmux' },
    nextMessage: async () => null,
    signal: abortController.signal,
    resolveHostAdapter: async () => ({ status: 'resolved', adapter, reason: 'test' }),
    readTerminalHostAttachmentInfo: async () => null,
    persistTerminalHostAttachmentInfo: async () => undefined,
    buildSpawn: async () => ({ spawnArgv: ['/bin/claude'], spawnEnv: {} }),
    createSessionName: () => 'happier-blocked-apply-clear',
    processSignals: null,
    tuiRuntimeControl: {
      featureEnabled: true,
      emitRuntimeConfigOutcome: vi.fn(),
      createBridge: () => createBridge(params.applies),
      onBlockedApplyClear,
    },
    createController: async ({ inputInjection }: { inputInjection: TerminalInputInjectionV1 }) => ({
      run: async () => {
        try {
          for (let index = 0; index < params.prompts; index += 1) {
            const result = await inputInjection.injectUserPrompt({ text: `prompt ${index}`, multiline: false } as TerminalPromptInput);
            statuses.push(result.status);
          }
        } finally {
          abortController.abort();
        }
      },
      dispose: async () => undefined,
    }),
  });
  return { onBlockedApplyClear, statuses };
}

describe('runClaudeUnifiedTerminalSession runtime-control clear wake', () => {
  // Live, runner pid 63291 (2026-11-16): every injection attempt passed the runtime-control gate
  // and fired the clear wake, which re-armed Pending materialization. A head the draft guard then
  // deferred woke the pending pump again at once: ~5 guard passes and two server reads per second
  // for as long as a user draft stayed in Claude's composer.
  it('does not wake Pending when no runtime-control apply was blocked', async () => {
    const { onBlockedApplyClear, statuses } = await injectThroughRuntimeControlGate({ applies: [], prompts: 3 });

    expect(statuses).toEqual(['injected', 'injected', 'injected']);
    expect(onBlockedApplyClear).not.toHaveBeenCalled();
  });

  it('wakes Pending once when an apply that was blocked can proceed again', async () => {
    const { onBlockedApplyClear, statuses } = await injectThroughRuntimeControlGate({
      applies: [
        { promptMayProceed: false, attempted: true, blockedReason: 'user_draft' },
        { promptMayProceed: false, attempted: true, blockedReason: 'user_draft' },
        { promptMayProceed: true, attempted: true },
        { promptMayProceed: true, attempted: false },
      ],
      prompts: 4,
    });

    expect(statuses).toEqual(['deferred', 'deferred', 'injected', 'injected']);
    expect(onBlockedApplyClear).toHaveBeenCalledTimes(1);
  });
});

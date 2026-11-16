import { afterEach, describe, expect, it, vi } from 'vitest';

import { TerminalHostStartupError } from '@/integrations/terminalHost/errors';
import { ZellijActionTimeoutError } from '@/integrations/zellij/actions';
import { ClaudeUnifiedTerminalManagedSettingsOptionError } from './buildClaudeUnifiedTerminalSpawn';
import { ClaudeUnifiedTerminalHostDeadError } from './createClaudeUnifiedController';
import { ClaudeUnifiedTerminalHookActivationError } from './claudeUnifiedHookActivation';
import { ClaudeUnifiedTerminalReadinessTimeoutError } from './createClaudeUnifiedTerminalReadinessBridge';
import {
  ClaudeUnifiedTerminalInjectionFailureError,
  isClaudeUnifiedTerminalAmbiguousInjectionFailureError,
} from './terminalInjectionFailureError';

const loggerMock = vi.hoisted(() => ({
  debug: vi.fn(),
}));

vi.mock('@/ui/logger', () => ({
  logger: loggerMock,
}));

import {
  isClaudeUnifiedTerminalRuntimeIssueError,
  surfaceClaudeUnifiedTerminalRuntimeIssue,
} from './surfaceClaudeUnifiedTerminalRuntimeIssue';

function buildInjectionFailureError(
  failureState: 'failed_terminal' | 'failed_ambiguous' = 'failed_terminal',
): ClaudeUnifiedTerminalInjectionFailureError {
  return new ClaudeUnifiedTerminalInjectionFailureError({
    batch: {
      message: 'hello',
      origin: { kind: 'ui_pending' },
      ...(failureState === 'failed_ambiguous' ? { userMessageLocalIds: ['pending-local'] } : {}),
    },
    result: {
      status: 'failed',
      reason: 'timeout',
      phase: 'after_enter_unknown',
      duplicateRisk: 'likely',
      recoverable: true,
    },
    failureState,
  });
}

function buildRecoverableAmbiguousInjectionFailureError(): ClaudeUnifiedTerminalInjectionFailureError {
  return new ClaudeUnifiedTerminalInjectionFailureError({
    batch: {
      message: 'hello',
      origin: { kind: 'ui_pending' },
      userMessageLocalIds: ['pending-local'],
    },
    result: {
      status: 'failed',
      reason: 'timeout',
      phase: 'after_write_before_enter',
      duplicateRisk: 'possible',
      recoverable: true,
    },
    failureState: 'failed_ambiguous',
  });
}

function buildReadinessTimeoutError(): ClaudeUnifiedTerminalReadinessTimeoutError {
  return new ClaudeUnifiedTerminalReadinessTimeoutError({
    timeoutMs: 250,
    handle: {
      kind: 'tmux',
      sessionName: 'happier-claude-session-test',
      paneId: '1',
      attachMetadata: {
        attachStrategy: 'terminal_host',
        topology: 'shared',
        locality: 'same_machine',
        maxClients: null,
        requiresLocalAttachmentInfo: true,
        liveProbe: 'required',
      },
    },
  });
}

function buildTerminalHostStartupError(): TerminalHostStartupError {
  return new TerminalHostStartupError({
    hostKind: 'zellij',
    reason: 'pane_disappeared_after_bootstrap_cleanup',
    message: 'zellij launched terminal pane disappeared after bootstrap cleanup',
  });
}

describe('surfaceClaudeUnifiedTerminalRuntimeIssue', () => {
  afterEach(() => {
    loggerMock.debug.mockClear();
  });

  it('classifies host-dead, terminal injection-failure, readiness-timeout, and host-startup failures as runtime issues', () => {
    expect(isClaudeUnifiedTerminalRuntimeIssueError(new ClaudeUnifiedTerminalHostDeadError())).toBe(true);
    expect(isClaudeUnifiedTerminalRuntimeIssueError(new ClaudeUnifiedTerminalHookActivationError())).toBe(true);
    expect(isClaudeUnifiedTerminalRuntimeIssueError(buildInjectionFailureError())).toBe(true);
    expect(isClaudeUnifiedTerminalRuntimeIssueError(buildReadinessTimeoutError())).toBe(true);
    expect(isClaudeUnifiedTerminalRuntimeIssueError(buildTerminalHostStartupError())).toBe(true);
    expect(isClaudeUnifiedTerminalRuntimeIssueError(new ZellijActionTimeoutError('list-panes'))).toBe(true);
    expect(isClaudeUnifiedTerminalRuntimeIssueError(
      new ClaudeUnifiedTerminalManagedSettingsOptionError([
        { code: 'managed_settings_option', option: '--settings' },
      ]),
    )).toBe(true);
  });

  it('classifies structurally wrapped terminal-host startup failures as runtime issues', () => {
    expect(isClaudeUnifiedTerminalRuntimeIssueError({
      code: 'terminal_host_startup_failed',
      hostKind: 'zellij',
      reason: 'pane_disappeared_after_bootstrap_cleanup',
      message: 'zellij launched terminal pane disappeared after bootstrap cleanup',
    })).toBe(true);
  });

  it('does not classify recoverable ambiguous injection failures as terminal runtime issues', () => {
    expect(isClaudeUnifiedTerminalRuntimeIssueError(buildRecoverableAmbiguousInjectionFailureError())).toBe(false);
  });

  it('classifies host-unreachable submit failures after Enter as terminal runtime issues', () => {
    expect(isClaudeUnifiedTerminalRuntimeIssueError(
      new ClaudeUnifiedTerminalInjectionFailureError({
        batch: {
          message: 'hello',
          origin: { kind: 'ui_pending' },
        },
        result: {
          status: 'failed',
          reason: 'host_unreachable',
          phase: 'after_enter_unknown',
          duplicateRisk: 'possible',
          recoverable: true,
        },
        failureState: 'failed_ambiguous',
      }),
    )).toBe(true);
  });

  it('leaves an unverified submit with Pending-owned local ids to the ambiguous path instead of failing the turn', () => {
    // Pending blocked incident (2026-11-16): Enter was pressed, the screen never confirmed it, and
    // the rows were still in Pending custody. Surfacing it as a runtime issue allocated a failed
    // turn ("Turn failed") although the prompt may well have reached Claude.
    const verificationFailedAfterEnter = (userMessageLocalIds: string[]) => new ClaudeUnifiedTerminalInjectionFailureError({
      batch: {
        message: 'hello',
        origin: { kind: 'ui_pending' },
        userMessageLocalIds,
      },
      result: {
        status: 'failed',
        reason: 'verification_failed',
        phase: 'after_enter_unknown',
        duplicateRisk: 'possible',
        recoverable: true,
      },
      failureState: 'failed_ambiguous',
    });

    const pendingOwned = verificationFailedAfterEnter(['pending-local-after-enter']);
    expect(isClaudeUnifiedTerminalRuntimeIssueError(pendingOwned)).toBe(false);
    expect(isClaudeUnifiedTerminalAmbiguousInjectionFailureError(pendingOwned)).toBe(true);

    // Without a Pending row there is nothing to mark uncertain; the turn failure stays the signal.
    expect(isClaudeUnifiedTerminalRuntimeIssueError(verificationFailedAfterEnter([]))).toBe(true);
  });

  it('classifies provider-acceptance timeouts without pending local ids as terminal runtime issues', () => {
    expect(isClaudeUnifiedTerminalRuntimeIssueError(
      new ClaudeUnifiedTerminalInjectionFailureError({
        batch: {
          message: 'hello',
          origin: { kind: 'ui_pending' },
          userMessageLocalIds: [],
        },
        result: {
          status: 'failed',
          reason: 'timeout',
          phase: 'after_enter_unknown',
          duplicateRisk: 'likely',
          recoverable: true,
        },
        failureState: 'failed_ambiguous',
      }),
    )).toBe(true);
    expect(isClaudeUnifiedTerminalRuntimeIssueError(buildInjectionFailureError('failed_ambiguous'))).toBe(true);
  });

  it('does not classify unrelated errors as runtime issues', () => {
    expect(isClaudeUnifiedTerminalRuntimeIssueError(new Error('boom'))).toBe(false);
    expect(isClaudeUnifiedTerminalRuntimeIssueError(null)).toBe(false);
    expect(isClaudeUnifiedTerminalRuntimeIssueError({ code: 'something_else' })).toBe(false);
  });

  it('surfaces a primary runtime issue through the session turn lifecycle for each classified error', async () => {
    for (const error of [
      new ClaudeUnifiedTerminalHostDeadError(),
      new ClaudeUnifiedTerminalHookActivationError(),
      buildInjectionFailureError(),
      buildReadinessTimeoutError(),
      buildTerminalHostStartupError(),
      new ClaudeUnifiedTerminalManagedSettingsOptionError([
        { code: 'managed_settings_option', option: '--settings' },
      ]),
    ]) {
      const failTurn = vi.fn(async () => {});
      const session = {
        sessionTurnLifecycle: {
          beginTurn: vi.fn(async () => ({ turnId: 't1' })),
          completeTurn: vi.fn(async () => {}),
          cancelTurn: vi.fn(async () => {}),
          failTurn,
        },
      } as unknown as Parameters<typeof surfaceClaudeUnifiedTerminalRuntimeIssue>[0]['session'];

      const surfaced = await surfaceClaudeUnifiedTerminalRuntimeIssue({ error, session });
      expect(surfaced).toBe(true);
      // Session-scoped deaths (host dead, readiness timeout, injection failure)
      // routinely occur with no active turn; the surfacing must allocate one so
      // the issue is not silently dropped (incident cmq8y3nlx / QA A-F4).
      expect(failTurn).toHaveBeenCalledWith({
        provider: 'claude',
        issue: expect.objectContaining({ provider: 'claude' }),
        allocateWhenIdle: true,
      });
    }
  });

  it('logs terminal host startup diagnostics before surfacing the runtime issue', async () => {
    const startupError = new TerminalHostStartupError({
      hostKind: 'zellij',
      reason: 'startup_action_failed',
      message: 'zellij run failed: run stderr',
      diagnostics: {
        action: 'run',
        cmd: [
          '/tools/zellij',
          '-s',
          'session-a',
          'run',
          '--',
          '/managed/node',
          'claude_local_launcher.cjs',
        ],
        exitCode: 2,
        stderr: 'run stderr',
        stdout: 'run stdout',
        sessionName: 'session-a',
        timeoutMs: 123,
      },
    });
    const session = {
      sessionTurnLifecycle: {
        beginTurn: vi.fn(async () => ({ turnId: 't1' })),
        completeTurn: vi.fn(async () => {}),
        cancelTurn: vi.fn(async () => {}),
        failTurn: vi.fn(async () => {}),
      },
    } as unknown as Parameters<typeof surfaceClaudeUnifiedTerminalRuntimeIssue>[0]['session'];

    await expect(surfaceClaudeUnifiedTerminalRuntimeIssue({ error: startupError, session })).resolves.toBe(true);

    expect(loggerMock.debug).toHaveBeenCalledWith(
      '[unified]: Claude unified terminal host startup failed before injection',
      expect.objectContaining({
        hostKind: 'zellij',
        reason: 'startup_action_failed',
        action: 'run',
        cmd: [
          '/tools/zellij',
          '-s',
          'session-a',
          'run',
          '--',
          '/managed/node',
          'claude_local_launcher.cjs',
        ],
        exitCode: 2,
        stderr: 'run stderr',
        timeoutMs: 123,
      }),
    );
  });

  it('does not surface or touch the session for an unrelated error', async () => {
    const failTurn = vi.fn(async () => {});
    const session = {
      sessionTurnLifecycle: {
        beginTurn: vi.fn(async () => ({ turnId: 't1' })),
        completeTurn: vi.fn(async () => {}),
        cancelTurn: vi.fn(async () => {}),
        failTurn,
      },
    } as unknown as Parameters<typeof surfaceClaudeUnifiedTerminalRuntimeIssue>[0]['session'];

    const surfaced = await surfaceClaudeUnifiedTerminalRuntimeIssue({
      error: new Error('unrelated'),
      session,
    });
    expect(surfaced).toBe(false);
    expect(failTurn).not.toHaveBeenCalled();
  });

  it('does not surface recoverable ambiguous injection failures through the primary turn lifecycle', async () => {
    const failTurn = vi.fn(async () => {});
    const session = {
      sessionTurnLifecycle: {
        beginTurn: vi.fn(async () => ({ turnId: 't1' })),
        completeTurn: vi.fn(async () => {}),
        cancelTurn: vi.fn(async () => {}),
        failTurn,
      },
    } as unknown as Parameters<typeof surfaceClaudeUnifiedTerminalRuntimeIssue>[0]['session'];

    const surfaced = await surfaceClaudeUnifiedTerminalRuntimeIssue({
      error: buildRecoverableAmbiguousInjectionFailureError(),
      session,
    });
    expect(surfaced).toBe(false);
    expect(failTurn).not.toHaveBeenCalled();
  });
});

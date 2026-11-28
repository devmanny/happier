import type { ClaudeUnifiedPromptInjectionFailure } from './_types';

export class ClaudeUnifiedTerminalInjectionFailureError extends Error {
  readonly code = 'claude_unified_terminal_injection_failed';
  readonly failureState: ClaudeUnifiedPromptInjectionFailure['failureState'];
  readonly reason: ClaudeUnifiedPromptInjectionFailure['result']['reason'];
  readonly phase: ClaudeUnifiedPromptInjectionFailure['result']['phase'];
  readonly duplicateRisk: ClaudeUnifiedPromptInjectionFailure['result']['duplicateRisk'];
  readonly recoverable: ClaudeUnifiedPromptInjectionFailure['result']['recoverable'];
  readonly pendingProviderAction: ClaudeUnifiedPromptInjectionFailure['batch']['pendingProviderAction'];
  readonly maxUserMessageSeq: number | null;
  readonly userMessageLocalIds: readonly string[];

  constructor(failure: ClaudeUnifiedPromptInjectionFailure) {
    super(
      failure.failureState === 'failed_ambiguous'
        ? 'Claude unified terminal prompt submission could not be confirmed'
        : 'Claude unified terminal prompt injection failed',
    );
    this.name = 'ClaudeUnifiedTerminalInjectionFailureError';
    this.failureState = failure.failureState;
    this.reason = failure.result.reason;
    this.phase = failure.result.phase;
    this.duplicateRisk = failure.result.duplicateRisk;
    this.recoverable = failure.result.recoverable;
    this.pendingProviderAction = failure.batch.pendingProviderAction;
    this.maxUserMessageSeq = failure.batch.maxUserMessageSeq ?? null;
    this.userMessageLocalIds = [...(failure.batch.userMessageLocalIds ?? [])];
  }
}

export function createClaudeUnifiedTerminalUnobservedFailedTurnError(): ClaudeUnifiedTerminalInjectionFailureError {
  return new ClaudeUnifiedTerminalInjectionFailureError({
    batch: {
      message: '',
      origin: { kind: 'ui_pending' },
      maxUserMessageSeq: null,
      userMessageLocalIds: [],
    },
    result: {
      status: 'failed',
      reason: 'timeout',
      phase: 'after_enter_unknown',
      duplicateRisk: 'likely',
      recoverable: true,
    },
    failureState: 'failed_terminal',
  });
}

export function isClaudeUnifiedTerminalInjectionFailureError(
  error: unknown,
): error is ClaudeUnifiedTerminalInjectionFailureError {
  return Boolean(error)
    && typeof error === 'object'
    && (error as { code?: unknown }).code === 'claude_unified_terminal_injection_failed';
}

export function isClaudeUnifiedTerminalAmbiguousInjectionFailureError(
  error: unknown,
): error is ClaudeUnifiedTerminalInjectionFailureError {
  return isClaudeUnifiedTerminalInjectionFailureError(error)
    && (error as { failureState?: unknown }).failureState === 'failed_ambiguous'
    && !isClaudeUnifiedTerminalUnconfirmedSubmitFailureError(error)
    && !isClaudeUnifiedTerminalProviderAcceptanceTimeoutError(error);
}

export function isClaudeUnifiedTerminalTerminalInjectionFailureError(
  error: unknown,
): error is ClaudeUnifiedTerminalInjectionFailureError {
  return isClaudeUnifiedTerminalInjectionFailureError(error)
    && (error as { failureState?: unknown }).failureState !== 'failed_ambiguous';
}

function hasUserMessageLocalIds(error: unknown): boolean {
  const raw = (error as { userMessageLocalIds?: unknown }).userMessageLocalIds;
  return Array.isArray(raw) && raw.some((value) => typeof value === 'string' && value.trim().length > 0);
}

export function isClaudeUnifiedTerminalUnclaimableProviderAcceptanceTimeoutError(
  error: unknown,
): error is ClaudeUnifiedTerminalInjectionFailureError {
  return isClaudeUnifiedTerminalProviderAcceptanceTimeoutError(error)
    && !hasUserMessageLocalIds(error);
}

export function isClaudeUnifiedTerminalProviderAcceptanceTimeoutError(
  error: unknown,
): error is ClaudeUnifiedTerminalInjectionFailureError {
  return isClaudeUnifiedTerminalInjectionFailureError(error)
    && (error as { failureState?: unknown }).failureState === 'failed_ambiguous'
    && (error as { reason?: unknown }).reason === 'timeout'
    && (error as { phase?: unknown }).phase === 'after_enter_unknown'
    && (error as { duplicateRisk?: unknown }).duplicateRisk !== 'none'
    && (error as { recoverable?: unknown }).recoverable === true;
}

/**
 * Enter was pressed but the submit could not be confirmed, and nothing else owns the uncertainty:
 * surfaced as a failed turn. A lost host stays here regardless of rows. An unverified screen with
 * rows still in Pending custody is left to the ambiguous path instead, which marks those rows
 * "not sure it reached the agent" (Pending blocked incident, 2026-11-16: the prompt may have
 * reached Claude, yet a failed turn was allocated).
 */
export function isClaudeUnifiedTerminalUnconfirmedSubmitFailureError(
  error: unknown,
): error is ClaudeUnifiedTerminalInjectionFailureError {
  const reason = (error as { reason?: unknown } | null)?.reason;
  return isClaudeUnifiedTerminalInjectionFailureError(error)
    && (error as { failureState?: unknown }).failureState === 'failed_ambiguous'
    && (reason === 'host_unreachable'
      || (reason === 'verification_failed' && !hasUserMessageLocalIds(error)))
    && (error as { phase?: unknown }).phase === 'after_enter_unknown';
}

export function isClaudeUnifiedTerminalRecoverableProviderAcceptanceUnknownFailure(
  error: unknown,
): error is ClaudeUnifiedTerminalInjectionFailureError {
  return isClaudeUnifiedTerminalInjectionFailureError(error)
    && (error as { failureState?: unknown }).failureState === 'failed_terminal'
    && (error as { reason?: unknown }).reason === 'timeout'
    && (error as { phase?: unknown }).phase === 'after_enter_unknown'
    && (error as { duplicateRisk?: unknown }).duplicateRisk !== 'none'
    && (error as { recoverable?: unknown }).recoverable === true;
}

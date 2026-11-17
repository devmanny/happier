import type { TerminalControlPort } from '@/integrations/terminalHost/controlTypes';
import { logger } from '@/ui/logger';

import {
  captureFailureToResult,
  captureScreenState,
  sendResultToFailure,
} from './controlRuntime';
import {
  captureComposerClearKeyEffect,
  createClaudeComposerClearKeyLedger,
  isSecondComposerClearEscapeWarranted,
  type ClaudeComposerClearKeyLedger,
} from './composerClearKeys';
import type { ClaudeScreenState } from './screenState';
import { isClaudeUsageLimitWaitBlockingComposerClear } from './screenState';

const DEFAULT_USER_AUTHORIZED_COMPOSER_CLEAR_SETTLE_MS = 250;

export type ClaudeComposerClearRefusalReason =
  | 'generating'
  | 'permission_prompt'
  | 'permission_editor'
  | 'trust_prompt'
  | 'switch_model_dialog'
  | 'resume_choice_dialog'
  | 'effort_change_dialog'
  | 'unrecognized_confirmation_dialog'
  | 'slash_picker'
  | 'selection_list'
  | 'usage_limit_wait'
  | 'no_interactive_composer'
  /** The composer text changed after the first Escape (someone is typing): never press again. */
  | 'draft_changed'
  /** Earlier clear keys of this pane still show no effect on the screen; another could open Rewind. */
  | 'unacknowledged_clear_keys';

export type ClaudeUserAuthorizedComposerClearResult =
  | Readonly<{ status: 'already_empty'; screen: ClaudeScreenState }>
  | Readonly<{ status: 'cleared'; screen: ClaudeScreenState; attempts: number }>
  | Readonly<{ status: 'refused'; reason: ClaudeComposerClearRefusalReason; screen: ClaudeScreenState }>
  | Readonly<{ status: 'unsupported'; reason?: string | undefined }>
  | Readonly<{ status: 'failed'; reason: string; screen?: ClaudeScreenState | undefined }>;

type ComposerClearScreenClassification =
  | Readonly<{ kind: 'empty'; screen: ClaudeScreenState }>
  | Readonly<{ kind: 'clearable_draft'; screen: ClaudeScreenState }>
  | Readonly<{ kind: 'refused'; reason: ClaudeComposerClearRefusalReason; screen: ClaudeScreenState }>;

function toComposerClearFailure(
  result: ReturnType<typeof captureFailureToResult> | NonNullable<ReturnType<typeof sendResultToFailure>>,
): ClaudeUserAuthorizedComposerClearResult {
  if (result.kind === 'unsupported') return { status: 'unsupported', reason: result.reason };
  if (result.kind === 'failed') return { status: 'failed', reason: result.reason };
  return { status: 'failed', reason: result.kind };
}

function classifyComposerClearScreen(state: ClaudeScreenState): ComposerClearScreenClassification {
  if (state.generating || state.queuedMessageBannerVisible) {
    return { kind: 'refused', reason: 'generating', screen: state };
  }
  if (state.permissionPromptVisible) {
    return { kind: 'refused', reason: 'permission_prompt', screen: state };
  }
  if (state.permissionEditorOpen) {
    return { kind: 'refused', reason: 'permission_editor', screen: state };
  }
  if (state.trustFolderPromptVisible) {
    return { kind: 'refused', reason: 'trust_prompt', screen: state };
  }
  if (state.switchModelDialogVisible) {
    return { kind: 'refused', reason: 'switch_model_dialog', screen: state };
  }
  if (state.resumeChoiceDialogVisible) {
    return { kind: 'refused', reason: 'resume_choice_dialog', screen: state };
  }
  if (state.effortChangeDialogVisible) {
    return { kind: 'refused', reason: 'effort_change_dialog', screen: state };
  }
  if (state.unrecognizedConfirmationDialogVisible) {
    return { kind: 'refused', reason: 'unrecognized_confirmation_dialog', screen: state };
  }
  if (state.slashPickerOpen) {
    return { kind: 'refused', reason: 'slash_picker', screen: state };
  }
  if (state.selectionListVisible) {
    return { kind: 'refused', reason: 'selection_list', screen: state };
  }
  if (isClaudeUsageLimitWaitBlockingComposerClear(state)) {
    return { kind: 'refused', reason: 'usage_limit_wait', screen: state };
  }
  if (!state.inputBoxInteractive || state.composerContent === null) {
    return { kind: 'refused', reason: 'no_interactive_composer', screen: state };
  }
  if (state.composerContent.length === 0) {
    return { kind: 'empty', screen: state };
  }
  return { kind: 'clearable_draft', screen: state };
}

type UserAuthorizedComposerClearOptions = Readonly<{
  port: TerminalControlPort;
  /**
   * The pane's session-scoped clear-key ledger, shared with the own-leftover clearers so the
   * Escapes of every sender stay within what Claude absorbs. Without it the bound holds only
   * within this call.
   */
  clearKeys?: ClaudeComposerClearKeyLedger | undefined;
  wait?: ((ms: number) => Promise<void>) | undefined;
  settleMs?: number | undefined;
}>;

type UserAuthorizedComposerClearEvidence = {
  escapesSent: number;
  initialScreen: ClaudeScreenState | null;
  /** The capture the second-Escape decision read (after the first Escape). */
  afterFirstEscapeScreen: ClaudeScreenState | null;
};

/**
 * The one path allowed to clear a composer draft Happier did not write, and only on an explicit
 * user request. It never types: it presses Escape onto a safe idle composer and verifies the result.
 * Claude 2.1.322 needs two Escapes for a draft (the first arms "Esc again to clear"), so the second
 * is pressed only on {@link isSecondComposerClearEscapeWarranted} evidence read from
 * {@link captureComposerClearKeyEffect}, the rule the own-leftover clearers use too, and every press
 * goes through the pane's clear-key ledger.
 */
export async function clearUserAuthorizedClaudeComposerDraft(
  params: UserAuthorizedComposerClearOptions,
): Promise<ClaudeUserAuthorizedComposerClearResult> {
  const evidence: UserAuthorizedComposerClearEvidence = {
    escapesSent: 0,
    initialScreen: null,
    afterFirstEscapeScreen: null,
  };
  const result = await runUserAuthorizedComposerClear(params, evidence);
  // One info line per request so a phone-side clear is explainable from the runner log. Never the
  // composer text.
  logger.infoFile('[unified]: user-authorized composer clear outcome', {
    status: result.status,
    ...('reason' in result && result.reason !== undefined ? { reason: result.reason } : {}),
    escapesSent: evidence.escapesSent,
    escapeAgainToClearHintBefore: evidence.initialScreen?.escapeAgainToClearHintVisible ?? null,
    escapeAgainToClearHintAfter: evidence.afterFirstEscapeScreen?.escapeAgainToClearHintVisible ?? null,
    composerLength: evidence.initialScreen?.composerContent?.length ?? null,
  });
  return result;
}

async function runUserAuthorizedComposerClear(
  params: UserAuthorizedComposerClearOptions,
  evidence: UserAuthorizedComposerClearEvidence,
): Promise<ClaudeUserAuthorizedComposerClearResult> {
  const settleMs = Math.max(
    0,
    Math.trunc(params.settleMs ?? DEFAULT_USER_AUTHORIZED_COMPOSER_CLEAR_SETTLE_MS),
  );
  const wait = params.wait ?? ((ms: number) => new Promise<void>((resolve) => {
    const timer = setTimeout(resolve, ms);
    timer.unref?.();
  }));
  const clearKeys = params.clearKeys ?? createClaudeComposerClearKeyLedger({ stallBudgetMs: Number.POSITIVE_INFINITY });

  async function capture(): Promise<ComposerClearScreenClassification | ClaudeUserAuthorizedComposerClearResult> {
    const captured = await captureScreenState(params.port);
    if (captured.kind !== 'state') return toComposerClearFailure(captureFailureToResult(captured));
    clearKeys.observe(captured.state.text);
    evidence.initialScreen ??= captured.state;
    return classifyComposerClearScreen(captured.state);
  }

  /** Presses one Escape onto `screen`; a result when it was withheld or could not be sent. */
  async function pressEscape(screen: ClaudeScreenState): Promise<ClaudeUserAuthorizedComposerClearResult | null> {
    if (!clearKeys.mayPress()) return { status: 'refused', reason: 'unacknowledged_clear_keys', screen };
    clearKeys.recordPress(screen.text);
    evidence.escapesSent += 1;
    const sendFailure = sendResultToFailure(await params.port.sendSpecialKey('Escape'));
    return sendFailure ? toComposerClearFailure(sendFailure) : null;
  }

  const initial = await capture();
  if (!('kind' in initial)) return initial;
  switch (initial.kind) {
    case 'empty':
      return { status: 'already_empty', screen: initial.screen };
    case 'refused':
      return { status: 'refused', reason: initial.reason, screen: initial.screen };
    case 'clearable_draft':
      break;
  }

  let before = initial.screen;
  for (let attempt = 1; ; attempt += 1) {
    const pressFailure = await pressEscape(before);
    if (pressFailure) return pressFailure;

    const after = await captureComposerClearKeyEffect({
      pressedFrameText: before.text,
      capture,
      frameTextOf: (captured) => ('kind' in captured ? captured.screen.text : null),
      wait,
      settleMs,
    });
    if (!('kind' in after)) return after;
    if (attempt === 1) evidence.afterFirstEscapeScreen = after.screen;
    switch (after.kind) {
      case 'empty':
        return { status: 'cleared', screen: after.screen, attempts: attempt };
      case 'refused':
        return { status: 'refused', reason: after.reason, screen: after.screen };
      case 'clearable_draft':
        break;
    }
    // Never a third Escape: the first arms the hint and the second clears.
    if (attempt >= 2) return { status: 'failed', reason: 'clear_failed', screen: after.screen };
    if (after.screen.composerContent !== before.composerContent) {
      return { status: 'refused', reason: 'draft_changed', screen: after.screen };
    }
    if (!isSecondComposerClearEscapeWarranted(before, after.screen)) {
      return { status: 'failed', reason: 'clear_failed', screen: after.screen };
    }
    before = after.screen;
  }
}

import { logger } from '@/ui/logger';

import { isClaudeUsageLimitWaitBlockingComposerClear, parseClaudeScreenState, type ClaudeScreenState } from './tuiControls/screenState';
import {
  classifyClaudeOwnComposerDraft,
  type ClaudeOwnComposerDraftClassification,
} from './ownComposerDraftClassification';
import { resolveClaudeUnifiedDialogBlockedReason } from './tuiControls/dialogRegistry';
import {
  captureComposerClearKeyEffect,
  createClaudeComposerClearKeyLedger,
  isSecondComposerClearEscapeWarranted,
  type ClaudeComposerClearKeyLedger,
} from './tuiControls/composerClearKeys';

const DEFAULT_DRAFT_CLEAR_SETTLE_MS = 250;
// Claude 2.1.322 takes two Escapes to clear composer text (the first arms "Esc again to clear"), so
// at most two per pass, the second only on isSecondComposerClearEscapeWarranted evidence.
export const MAX_OWN_LEFTOVER_DRAFT_CLEAR_ATTEMPTS = 2;
// Escape walks the feedback card's states (send confirmation -> card -> turn-off prompt -> gone).
const MAX_FEEDBACK_DRAFT_CARD_DISMISS_ATTEMPTS = 3;
// Claude 2.1.322 ignores Escape on the card for 600ms after a turn ends; space presses past that.
const FEEDBACK_DRAFT_CARD_DISMISS_SETTLE_MS = 700;

export type OwnComposerDraftGuardResult =
  | Readonly<{ status: 'no_draft'; screen: ClaudeScreenState }>
  | Readonly<{ status: 'cleared'; screen: ClaudeScreenState; attempts: number }>
  /** Composer holds text we did NOT write — a genuine user draft that must never be touched. */
  | Readonly<{ status: 'foreign_draft'; screen: ClaudeScreenState }>
  /** Composer text may be a dim Claude suggestion, but the capture lacks style evidence. */
  | Readonly<{ status: 'capture_style_unavailable'; screen: ClaudeScreenState }>
  /** Provider is known unavailable from the visible Claude TUI state; this is not a user draft. */
  | Readonly<{ status: 'provider_unavailable'; screen: ClaudeScreenState }>
  /** A dialog/editor/selection state owns input; this is not a user draft. */
  | Readonly<{ status: 'blocked_non_input_state'; screen: ClaudeScreenState; blockedReason: string }>
  /** Screen is generating: the clear key (Escape) would interrupt the running turn. */
  | Readonly<{ status: 'generating'; screen: ClaudeScreenState }>
  | Readonly<{ status: 'capture_failed' }>
  | Readonly<{ status: 'clear_failed'; screen: ClaudeScreenState }>;

/**
 * C11 (incident cmq8y3nlx): bounded clear of OUR OWN leftover composer text before acting on the
 * composer. The leftover classifier is the own-injected-text registry (`ownComposerTextLog`,
 * respawn-seeded from the persisted prompt store), so both the in-flight steer evaluator and the
 * idle pre-injection guard share one owner for "is this draft ours?" — a genuine user draft is
 * NEVER touched, and nothing is cleared while the screen is generating.
 *
 * Live-proven defect this guards (runner pid 83791, 09:34): idle injection typed the new prompt
 * AFTER a predecessor's leftover injection and submitted the concatenation as one corrupted prompt.
 */
export async function clearOwnLeftoverComposerDraft(
  opts: OwnComposerDraftGuardOptions,
): Promise<OwnComposerDraftGuardResult> {
  const evidence: OwnComposerDraftGuardEvidence = { classification: null, clearKeysSent: 0, clearKeyWithheld: false };
  const result = await runOwnComposerDraftGuard(opts, evidence);
  // Info level by default: a deferral that leaves a draft in Claude's composer must be explainable
  // from the runner log (incident 2026-11-16 had only debug telemetry). Never the composer text.
  (opts.outcomeLog ?? createClaudeOwnComposerDraftGuardOutcomeLog()).observe({
    status: result.status,
    classification: evidence.classification,
    ...('screen' in result
      ? {
          composerLength: result.screen.composerContent?.length ?? null,
          escapeAgainToClearHintVisible: result.screen.escapeAgainToClearHintVisible,
          selectionListVisible: result.screen.selectionListVisible,
        }
      : {}),
    clearKeysSent: evidence.clearKeysSent,
    ...(evidence.clearKeyWithheld ? { clearKeyWithheld: true } : {}),
    ...('blockedReason' in result ? { blockedReason: result.blockedReason } : {}),
  });
  return result;
}

/** What one guard pass saw and did; logged without the composer text. */
type OwnComposerDraftGuardOutcomeFields = Readonly<{
  status: OwnComposerDraftGuardResult['status'];
  classification: ClaudeOwnComposerDraftClassification | null;
  composerLength?: number | null;
  escapeAgainToClearHintVisible?: boolean;
  selectionListVisible?: boolean;
  clearKeysSent: number;
  clearKeyWithheld?: true;
  blockedReason?: string;
}>;

export type ClaudeOwnComposerDraftGuardOutcomeLog = Readonly<{
  observe(fields: OwnComposerDraftGuardOutcomeFields): void;
  /** Logs the identical passes since the last line; the session owner calls it on teardown. */
  flush(): void;
}>;

/**
 * How often an unchanged outcome still logs its repeat count. A held draft is rechecked at most
 * every 30 s once the injector backs off, so a line reports ~20 repeats; a hot loop reports
 * thousands, which is the signal (runner pid 63291) the dedupe must not hide.
 */
const OUTCOME_REPEAT_HEARTBEAT_MS = 10 * 60_000;

/**
 * Session-scoped log of guard outcomes. A pass logs only when its outcome differs from the last
 * logged one, and then says how many identical passes it skipped: a draft the user leaves in the
 * composer repeats one outcome on every recheck (runner pid 63291 logged it ~5 times per second
 * for 10 hours). An unchanged outcome still logs its repeat count every heartbeat and on flush.
 */
export function createClaudeOwnComposerDraftGuardOutcomeLog(params?: Readonly<{
  nowMs?: (() => number) | undefined;
}>): ClaudeOwnComposerDraftGuardOutcomeLog {
  const nowMs = params?.nowMs ?? Date.now;
  let lastLogged: Readonly<{ key: string; fields: OwnComposerDraftGuardOutcomeFields }> | null = null;
  let lastLoggedAtMs = 0;
  let repeatsSinceLastLogged = 0;
  const log = (fields: OwnComposerDraftGuardOutcomeFields): void => {
    logger.infoFile('[unified]: composer draft guard outcome', {
      ...fields,
      ...(repeatsSinceLastLogged > 0 ? { repeatsSinceLastLogged } : {}),
    });
    lastLoggedAtMs = nowMs();
    repeatsSinceLastLogged = 0;
  };
  return {
    observe(fields) {
      const key = JSON.stringify(fields);
      if (key === lastLogged?.key) {
        repeatsSinceLastLogged += 1;
        if (nowMs() - lastLoggedAtMs >= OUTCOME_REPEAT_HEARTBEAT_MS) log(fields);
        return;
      }
      log(fields);
      lastLogged = { key, fields };
    },
    flush() {
      if (lastLogged && repeatsSinceLastLogged > 0) log(lastLogged.fields);
    },
  };
}

type OwnComposerDraftGuardOptions = Readonly<{
  /**
   * The pane's outcome log, so a pass logs only what changed since the session's last logged
   * outcome. Without it this pass logs its outcome unconditionally.
   */
  outcomeLog?: ClaudeOwnComposerDraftGuardOutcomeLog | undefined;
  captureInputState: () => Promise<Readonly<{
    currentInput: string;
    cursor?: Readonly<{ x: number; y: number }> | undefined;
  }>>;
  /** Sends ONE composer-clear keypress (Escape). Only invoked for exact-match own leftovers. */
  sendClearKey: () => Promise<void>;
  /**
   * The pane's session-scoped clear-key ledger, shared with the steer evaluator's own-leftover
   * clear and the user-authorized clear. Without it the outstanding-key bound holds only within
   * this call.
   */
  clearKeys?: ClaudeComposerClearKeyLedger | undefined;
  ownComposerTexts: Readonly<{ matches: (draft: string) => boolean }>;
  /**
   * The session's canonical turn state. While a turn is live Escape interrupts it, and right after
   * Enter Claude still draws the submitted prompt in the composer with no spinner (2.1.326), so
   * the screen alone cannot rule that out (incident cmwyimjvw4buyqh01nx3pp1oh). While this reports
   * true no clear key is sent and the pass reports `provider_turn_active`.
   */
  isProviderTurnActive?: (() => boolean) | undefined;
  settleMs?: number | undefined;
  wait?: ((ms: number) => Promise<void>) | undefined;
  /** Telemetry tap: fired after each clear attempt with the recaptured screen. */
  onClearAttempt?: ((info: Readonly<{ attempt: number; screen: ClaudeScreenState }>) => void) | undefined;
}>;

type OwnComposerDraftGuardEvidence = {
  /** Classification of the latest screen the guard read. */
  classification: ClaudeOwnComposerDraftClassification | null;
  clearKeysSent: number;
  /** A clear key was due but withheld because earlier ones still show no effect on the screen. */
  clearKeyWithheld: boolean;
};

async function runOwnComposerDraftGuard(
  opts: OwnComposerDraftGuardOptions,
  evidence: OwnComposerDraftGuardEvidence,
): Promise<OwnComposerDraftGuardResult> {
  const settleMs = Math.max(0, Math.trunc(opts.settleMs ?? DEFAULT_DRAFT_CLEAR_SETTLE_MS));
  const wait = opts.wait ?? ((ms: number) => new Promise<void>((resolve) => {
    const timer = setTimeout(resolve, ms);
    timer.unref?.();
  }));
  const clearKeys = opts.clearKeys ?? createClaudeComposerClearKeyLedger({ stallBudgetMs: Number.POSITIVE_INFINITY });

  async function capture(): Promise<Readonly<{ screen: ClaudeScreenState; rawText: string }> | null> {
    let captured: Readonly<{ screen: ClaudeScreenState; rawText: string }>;
    try {
      const inputState = await opts.captureInputState();
      const rawText = inputState.currentInput;
      captured = { screen: parseClaudeScreenState(rawText, { cursor: inputState.cursor }), rawText };
    } catch {
      return null;
    }
    clearKeys.observe(captured.screen.text);
    return captured;
  }

  function classify(captureResult: Readonly<{ screen: ClaudeScreenState; rawText: string }>) {
    evidence.classification = classifyClaudeOwnComposerDraft({
      screen: captureResult.screen,
      rawText: captureResult.rawText,
      ownComposerTexts: opts.ownComposerTexts,
    });
    return evidence.classification;
  }

  function providerTurnActive(): boolean {
    if (!opts.isProviderTurnActive) return false;
    try {
      return opts.isProviderTurnActive();
    } catch {
      return true;
    }
  }

  const turnActiveResult = (current: ClaudeScreenState): OwnComposerDraftGuardResult => (
    { status: 'blocked_non_input_state', screen: current, blockedReason: 'provider_turn_active' }
  );

  /** Presses one clear key onto `screen`; false when the ledger withholds it (nothing was sent). */
  async function pressClearKey(screen: ClaudeScreenState): Promise<boolean> {
    if (!clearKeys.mayPress()) {
      evidence.clearKeyWithheld = true;
      return false;
    }
    clearKeys.recordPress(screen.text);
    evidence.clearKeysSent += 1;
    await opts.sendClearKey();
    return true;
  }

  function resolveBlockedNonInputReason(screen: ClaudeScreenState): string {
    const dialogReason = resolveClaudeUnifiedDialogBlockedReason(screen);
    if (dialogReason) return dialogReason;
    if (screen.permissionPromptVisible) return 'permission_prompt';
    if (screen.trustFolderPromptVisible) return 'trust_folder_prompt';
    if (screen.permissionEditorOpen) return 'permission_editor';
    if (screen.selectionListVisible) return 'selection_list';
    if (screen.queuedMessageBannerVisible) return 'queued_message_banner';
    if (screen.generating) return 'generating';
    if (screen.composerContent === null) return 'no_interactive_composer';
    return 'non_input_state';
  }

  /** Result for every classification that ends the guard; null for `empty` and a clearable `own`. */
  function settledResult(
    classification: ReturnType<typeof classify>,
    screen: ClaudeScreenState,
  ): OwnComposerDraftGuardResult | null {
    switch (classification) {
      case 'empty':
        return null;
      case 'generating':
        return { status: 'generating', screen };
      case 'provider_unavailable':
        return { status: 'provider_unavailable', screen };
      case 'non_input_state':
        return { status: 'blocked_non_input_state', screen, blockedReason: resolveBlockedNonInputReason(screen) };
      case 'capture_style_unavailable':
        return { status: 'capture_style_unavailable', screen };
      case 'foreign':
        // A draft we did not write (or one that changed under us): stop, never touch it.
        return { status: 'foreign_draft', screen };
      case 'own':
        return isClaudeUsageLimitWaitBlockingComposerClear(screen)
          ? { status: 'blocked_non_input_state', screen, blockedReason: 'usage_limit_wait' }
          : null;
    }
  }

  /**
   * Empty composer: dismiss Claude's feedback draft card before anything is typed (incident
   * 2026-11-13). The card leaves typed text in the composer, but a prompt that is only `0`/`1`/`2`
   * would be consumed as a card hotkey (`2` twice sends the report). Escape is the card's own
   * dismiss key on an empty composer; it never sends, and the draft stays queued in `/feedback`.
   *
   * Every Escape here lands on an empty composer unless the card takes it, and Claude 2.1.322
   * reads two Escapes on an empty composer inside its 800 ms double-press window as Rewind, which
   * swallows the next paste (repro, 2026-11-16). So a dismissal is never chained right after our own
   * clear key emptied the composer (a later pass starts from that empty composer instead), and the
   * clear-key ledger keeps presses the screen has not shown within what the card absorbs.
   */
  async function settleEmptyComposer(
    screen: ClaudeScreenState,
    clearAttempts: number,
  ): Promise<OwnComposerDraftGuardResult> {
    const cardBlocked = (current: ClaudeScreenState): OwnComposerDraftGuardResult => (
      { status: 'blocked_non_input_state', screen: current, blockedReason: 'feedback_draft_card' }
    );
    if (clearAttempts > 0 && screen.feedbackDraftCardVisible) return cardBlocked(screen);
    let current = screen;
    for (let dismissal = 0; current.feedbackDraftCardVisible; dismissal += 1) {
      if (dismissal >= MAX_FEEDBACK_DRAFT_CARD_DISMISS_ATTEMPTS) return cardBlocked(current);
      if (providerTurnActive()) return turnActiveResult(current);
      try {
        if (!(await pressClearKey(current))) return cardBlocked(current);
      } catch {
        return { status: 'clear_failed', screen: current };
      }
      await wait(Math.max(settleMs, FEEDBACK_DRAFT_CARD_DISMISS_SETTLE_MS));
      const recaptured = await capture();
      if (!recaptured) return { status: 'capture_failed' };
      current = recaptured.screen;
      clearAttempts += 1;
      opts.onClearAttempt?.({ attempt: clearAttempts, screen: current });
      const settled = settledResult(classify(recaptured), current);
      if (settled) return settled;
      // Escape over an empty composer cannot produce own text; anything else is not ours to clear.
      if (current.composerContent !== '') return { status: 'foreign_draft', screen: current };
    }
    return clearAttempts === 0
      ? { status: 'no_draft', screen: current }
      : { status: 'cleared', screen: current, attempts: clearAttempts };
  }

  let captured = await capture();
  if (!captured) return { status: 'capture_failed' };
  let screen = captured.screen;
  const initial = classify(captured);
  const initialResult = settledResult(initial, screen);
  if (initialResult) return initialResult;
  if (initial === 'empty') return settleEmptyComposer(screen, 0);
  if (providerTurnActive()) return turnActiveResult(screen);

  for (let attempt = 1; ; attempt += 1) {
    const pressedOn = screen;
    try {
      if (!(await pressClearKey(pressedOn))) return { status: 'clear_failed', screen };
    } catch {
      return { status: 'clear_failed', screen };
    }
    const recaptured = await captureComposerClearKeyEffect({
      pressedFrameText: pressedOn.text,
      capture,
      frameTextOf: (result) => result?.screen.text ?? null,
      wait,
      settleMs,
    });
    if (!recaptured) return { status: 'capture_failed' };
    captured = recaptured;
    screen = recaptured.screen;
    opts.onClearAttempt?.({ attempt, screen });
    const classification = classify(captured);
    const settled = settledResult(classification, screen);
    if (settled) return settled;
    if (classification === 'empty') return settleEmptyComposer(screen, attempt);
    if (
      attempt >= MAX_OWN_LEFTOVER_DRAFT_CLEAR_ATTEMPTS
      || !isSecondComposerClearEscapeWarranted(pressedOn, screen)
    ) {
      return { status: 'clear_failed', screen };
    }
  }
}

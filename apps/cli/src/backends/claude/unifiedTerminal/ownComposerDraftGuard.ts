import { isClaudeUsageLimitWaitBlockingComposerClear, parseClaudeScreenState, type ClaudeScreenState } from './tuiControls/screenState';
import { classifyClaudeOwnComposerDraft } from './ownComposerDraftClassification';
import { resolveClaudeUnifiedDialogBlockedReason } from './tuiControls/dialogRegistry';

const DEFAULT_DRAFT_CLEAR_SETTLE_MS = 250;
// Same bounded semantics as the slash-control leftover clear (lane U): one clear key can leave the
// draft text behind, so allow a second press before giving up.
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
export async function clearOwnLeftoverComposerDraft(opts: Readonly<{
  captureInputState: () => Promise<Readonly<{
    currentInput: string;
    cursor?: Readonly<{ x: number; y: number }> | undefined;
  }>>;
  /** Sends ONE composer-clear keypress (Escape). Only invoked for exact-match own leftovers. */
  sendClearKey: () => Promise<void>;
  ownComposerTexts: Readonly<{ matches: (draft: string) => boolean }>;
  settleMs?: number | undefined;
  wait?: ((ms: number) => Promise<void>) | undefined;
  /** Telemetry tap: fired after each clear attempt with the recaptured screen. */
  onClearAttempt?: ((info: Readonly<{ attempt: number; screen: ClaudeScreenState }>) => void) | undefined;
}>): Promise<OwnComposerDraftGuardResult> {
  const settleMs = Math.max(0, Math.trunc(opts.settleMs ?? DEFAULT_DRAFT_CLEAR_SETTLE_MS));
  const wait = opts.wait ?? ((ms: number) => new Promise<void>((resolve) => {
    const timer = setTimeout(resolve, ms);
    timer.unref?.();
  }));

  async function capture(): Promise<Readonly<{ screen: ClaudeScreenState; rawText: string }> | null> {
    try {
      const inputState = await opts.captureInputState();
      const rawText = inputState.currentInput;
      return { screen: parseClaudeScreenState(rawText, { cursor: inputState.cursor }), rawText };
    } catch {
      return null;
    }
  }

  function classify(captureResult: Readonly<{ screen: ClaudeScreenState; rawText: string }>) {
    return classifyClaudeOwnComposerDraft({
      screen: captureResult.screen,
      rawText: captureResult.rawText,
      ownComposerTexts: opts.ownComposerTexts,
    });
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
   */
  async function settleEmptyComposer(
    screen: ClaudeScreenState,
    clearAttempts: number,
  ): Promise<OwnComposerDraftGuardResult> {
    let current = screen;
    for (let dismissal = 0; current.feedbackDraftCardVisible; dismissal += 1) {
      if (dismissal >= MAX_FEEDBACK_DRAFT_CARD_DISMISS_ATTEMPTS) {
        return { status: 'blocked_non_input_state', screen: current, blockedReason: 'feedback_draft_card' };
      }
      try {
        await opts.sendClearKey();
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

  for (let attempt = 1; attempt <= MAX_OWN_LEFTOVER_DRAFT_CLEAR_ATTEMPTS; attempt += 1) {
    try {
      await opts.sendClearKey();
    } catch {
      return { status: 'clear_failed', screen };
    }
    await wait(settleMs);
    const recaptured = await capture();
    if (!recaptured) return { status: 'capture_failed' };
    captured = recaptured;
    screen = recaptured.screen;
    opts.onClearAttempt?.({ attempt, screen });
    const classification = classify(captured);
    const settled = settledResult(classification, screen);
    if (settled) return settled;
    if (classification === 'empty') return settleEmptyComposer(screen, attempt);
  }
  return { status: 'clear_failed', screen };
}

import type { ClaudeScreenState } from './screenState';

// Claude 2.1.322 absorbs two Escapes from each state the clearers press on: own text (the first
// shows "Esc again to clear", the second clears) and the feedback card (the card, then its turn-off
// prompt). A queued burst of at most two therefore never lands two on an empty composer, which
// Claude reads as Rewind, and Rewind swallows the next paste (repro, 2026-11-16).
const MAX_UNACKNOWLEDGED_CLEAR_KEYS = 2;

/**
 * Session memory of the composer clear keys (Escape) whose effect the Claude screen has not shown.
 * A stalled Claude leaves its last frame in the pane and reads every queued key as one burst when
 * it resumes, so a fresh capture of an unchanged frame is no evidence that earlier keys landed.
 * The idle own-leftover guard (text and feedback-card Escapes), the in-flight steer evaluator's
 * own-leftover clear and the user-authorized clear of one pane share one ledger, and across all
 * their passes it keeps at most {@link MAX_UNACKNOWLEDGED_CLEAR_KEYS} keys outstanding. The slash
 * control's leftover clear (slashControls.ts) presses outside it. A capture that differs from the frame the
 * keys were pressed on acknowledges them. Past the session stall budget they are presumed absorbed
 * or dropped: a hint that came and went between two captures must not block clearing forever.
 */
export type ClaudeComposerClearKeyLedger = Readonly<{
  /** Feed every capture the clearer reads. */
  observe: (frameText: string) => void;
  /** Whether one more clear key may be pressed now. */
  mayPress: () => boolean;
  /** Record a clear key pressed onto this frame (before sending, so a failed send still counts). */
  recordPress: (frameText: string) => void;
}>;

export function createClaudeComposerClearKeyLedger(opts: Readonly<{
  /** The session stall budget: how long Claude may show no effect before the runner stops waiting. */
  stallBudgetMs: number;
  nowMs?: (() => number) | undefined;
}>): ClaudeComposerClearKeyLedger {
  const nowMs = opts.nowMs ?? Date.now;
  let outstanding: Readonly<{ frameText: string; keys: number; firstPressedAtMs: number }> | null = null;
  return {
    observe(frameText) {
      if (outstanding && outstanding.frameText !== frameText) outstanding = null;
    },
    mayPress() {
      if (outstanding && nowMs() - outstanding.firstPressedAtMs >= opts.stallBudgetMs) outstanding = null;
      return (outstanding?.keys ?? 0) < MAX_UNACKNOWLEDGED_CLEAR_KEYS;
    },
    recordPress(frameText) {
      outstanding = outstanding?.frameText === frameText
        ? { ...outstanding, keys: outstanding.keys + 1 }
        : { frameText, keys: 1, firstPressedAtMs: nowMs() };
    },
  };
}

// Recaptures after a clear key before deciding on its effect. Claude 2.1.322 keeps the double-press
// window 800 ms open after it takes the first Escape; with the 250 ms settle the last of three
// captures comes 750 ms after the key.
const MAX_CLEAR_KEY_EFFECT_CAPTURES = 3;

/**
 * Captures the screen after a clear key was pressed onto `pressedFrameText`: after each settle,
 * until a capture differs from that frame (or is no screen at all, `frameTextOf` null), at most
 * {@link MAX_CLEAR_KEY_EFFECT_CAPTURES} times. Returns the last capture. A lagging Claude repaints
 * late, and a capture of the unchanged frame is no evidence either way, so every composer clearer
 * decides on this capture, never on the first one after the settle.
 */
export async function captureComposerClearKeyEffect<T>(params: Readonly<{
  pressedFrameText: string;
  capture: () => Promise<T>;
  frameTextOf: (captured: T) => string | null;
  wait: (ms: number) => Promise<void>;
  settleMs: number;
}>): Promise<T> {
  for (let captures = 1; ; captures += 1) {
    await params.wait(params.settleMs);
    const captured = await params.capture();
    const frameText = params.frameTextOf(captured);
    if (frameText === null || frameText !== params.pressedFrameText) return captured;
    if (captures >= MAX_CLEAR_KEY_EFFECT_CAPTURES) return captured;
  }
}

/**
 * The one rule for a second clear Escape over composer text, used by every composer text clearer
 * (the own-leftover guard, the in-flight steer evaluator and the user-authorized clear): Claude
 * took the first Escape and kept the draft, so the second clears it. The evidence is the
 * "Esc again to clear" hint appearing over the same composer text, read from
 * {@link captureComposerClearKeyEffect}. Without it (a frame that never repainted, a hint already
 * armed before the first press so the first one cleared, or text that changed) a second Escape may
 * land on an empty composer, and two there open Rewind, which swallows the next paste (repro e,
 * 2026-11-16). The feedback-card dismissal presses on an empty composer and is bounded by the
 * ledger alone, because the card absorbs both keys.
 */
export function isSecondComposerClearEscapeWarranted(
  before: ClaudeScreenState,
  after: ClaudeScreenState,
): boolean {
  return !before.escapeAgainToClearHintVisible
    && after.escapeAgainToClearHintVisible
    && !!after.composerContent
    && after.composerContent === before.composerContent;
}

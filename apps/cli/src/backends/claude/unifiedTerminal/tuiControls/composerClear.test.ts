import { describe, expect, it, vi } from 'vitest';

import { logger } from '@/ui/logger';

import { clearUserAuthorizedClaudeComposerDraft } from './composerClear';
import { createClaudeComposerClearKeyLedger } from './composerClearKeys';
import { createFakeControlPort } from './fakeControlPort';
import { parseClaudeScreenState } from './screenState';

const EMPTY_COMPOSER = [
  '╭───────────────────────────────────────────────╮',
  '│ >                                               │',
  '╰───────────────────────────────────────────────╯',
  '  ? for shortcuts',
].join('\n');

function idleDraft(draft: string): string {
  return [
    '╭───────────────────────────────────────────────╮',
    `│ > ${draft}`,
    '╰───────────────────────────────────────────────╯',
    '  ? for shortcuts',
  ].join('\n');
}

function generatingDraft(draft: string): string {
  return [
    '● Working…',
    '✶ Forging… (12s · esc to interrupt)',
    '╭───────────────────────────────────────────────╮',
    `│ > ${draft}`,
    '╰───────────────────────────────────────────────╯',
  ].join('\n');
}

const RULE = '────────────────────────────────────────────────';

/** Claude 2.1.322 rule-boxed composer; the footer carries "Esc again to clear" after one Escape. */
function ruledDraft(draft: string, footer = '  ? for shortcuts'): string {
  return [RULE, `❯ ${draft}`, RULE, footer].join('\n');
}

function hintedDraft(draft: string): string {
  return ruledDraft(draft, '  Esc again to clear');
}

const PERMISSION_PROMPT = [
  'Bash(rm -rf tmp)',
  '',
  'Do you want to proceed?',
  '❯ 1. Yes',
  '  2. No, tell Claude what to do differently',
].join('\n');

const UNRECOGNIZED_DIALOG = [
  'Archive this conversation?',
  '',
  '❯ 1. Yes, archive',
  '  2. No, go back',
].join('\n');

const TRANSCRIPT_ONLY = [
  'Claude finished the previous answer.',
  'No composer visible in this capture.',
].join('\n');

describe('clearUserAuthorizedClaudeComposerDraft', () => {
  it('refuses Escape draft clearing while Claude owns an automatic usage-limit wait', async () => {
    const port = createFakeControlPort({ captures: [[
      idleDraft('my half-typed genuine thought'),
      '  ⚠ Usage limit reached · limit resets 5:10pm',
      '    Continuing automatically at 5:10pm · esc to cancel',
    ].join('\n')] });

    expect(await clearUserAuthorizedClaudeComposerDraft({
      port,
      wait: async () => undefined,
    })).toMatchObject({ status: 'refused', reason: 'usage_limit_wait' });
    expect(port.sentKeys).toEqual([]);
  });

  it('reports already_empty without pressing Escape when the composer has no draft', async () => {
    const port = createFakeControlPort({ captures: [EMPTY_COMPOSER] });

    const result = await clearUserAuthorizedClaudeComposerDraft({
      port,
      wait: async () => undefined,
      settleMs: 0,
    });

    expect(result.status).toBe('already_empty');
    expect(port.sentKeys).toEqual([]);
  });

  it('clears a safe visible user draft with Escape and verifies the composer is empty', async () => {
    const port = createFakeControlPort({
      captures: [idleDraft('my half-typed genuine thought'), EMPTY_COMPOSER],
    });

    const result = await clearUserAuthorizedClaudeComposerDraft({
      port,
      wait: async () => undefined,
      settleMs: 0,
    });

    expect(result).toMatchObject({ status: 'cleared', attempts: 1 });
    expect(port.sentKeys).toEqual(['Escape']);
    expect(port.log.map((entry) => entry.type)).toEqual(['capture', 'key', 'capture']);
  });

  it('allows a user-authorized slash draft clear when no slash picker or dialog owns input', async () => {
    const port = createFakeControlPort({
      captures: [idleDraft('/compact focus the summary'), EMPTY_COMPOSER],
    });

    const result = await clearUserAuthorizedClaudeComposerDraft({
      port,
      wait: async () => undefined,
      settleMs: 0,
    });

    expect(result).toMatchObject({ status: 'cleared', attempts: 1 });
    expect(port.sentKeys).toEqual(['Escape']);
  });

  it('presses the second Escape only after the hint for the same draft', async () => {
    const port = createFakeControlPort({
      captures: [
        ruledDraft('draft survives once'),
        hintedDraft('draft survives once'),
        EMPTY_COMPOSER,
      ],
    });

    const result = await clearUserAuthorizedClaudeComposerDraft({
      port,
      wait: async () => undefined,
      settleMs: 0,
    });

    expect(result).toMatchObject({ status: 'cleared', attempts: 2 });
    expect(port.sentKeys).toEqual(['Escape', 'Escape']);
  });

  it('reports clear_failed after bounded clear attempts leave the draft visible', async () => {
    const port = createFakeControlPort({
      captures: [ruledDraft('stuck draft'), hintedDraft('stuck draft'), hintedDraft('stuck draft')],
    });

    const result = await clearUserAuthorizedClaudeComposerDraft({
      port,
      wait: async () => undefined,
      settleMs: 0,
    });

    expect(result).toMatchObject({ status: 'failed', reason: 'clear_failed' });
    expect(port.sentKeys).toEqual(['Escape', 'Escape']);
  });

  // Rewind hazard (repro e, 2026-11-16): two Escapes on an empty composer open Claude's Rewind
  // selector, which swallows the next paste. The second Escape needs evidence that Claude took the
  // first one and kept the draft: the "Esc again to clear" hint appearing over the same text.
  it('stops after one Escape when Claude shows no "Esc again to clear"', async () => {
    const port = createFakeControlPort({
      captures: [ruledDraft('draft under a stalled frame'), ruledDraft('draft under a stalled frame')],
    });

    const result = await clearUserAuthorizedClaudeComposerDraft({
      port,
      wait: async () => undefined,
      settleMs: 0,
    });

    expect(result).toMatchObject({ status: 'failed', reason: 'clear_failed' });
    expect(port.sentKeys).toEqual(['Escape']);
  });

  it('waits for a lagging repaint of the hint before deciding on the second Escape', async () => {
    // Under load Claude may repaint after the first recapture; the stale frame is no evidence either
    // way, so the clear recaptures (inside Claude's 800 ms double-press window) until it changes.
    const port = createFakeControlPort({
      captures: [
        ruledDraft('draft behind a slow repaint'),
        ruledDraft('draft behind a slow repaint'),
        hintedDraft('draft behind a slow repaint'),
        EMPTY_COMPOSER,
      ],
    });
    const waits: number[] = [];

    const result = await clearUserAuthorizedClaudeComposerDraft({
      port,
      wait: async (ms) => { waits.push(ms); },
      settleMs: 250,
    });

    expect(result).toMatchObject({ status: 'cleared', attempts: 2 });
    expect(port.sentKeys).toEqual(['Escape', 'Escape']);
    expect(port.log.map((entry) => entry.type)).toEqual(['capture', 'key', 'capture', 'capture', 'key', 'capture']);
    expect(waits).toEqual([250, 250, 250]);
  });

  it('decides once the evidence window passes on a frame that never repaints', async () => {
    const port = createFakeControlPort({ captures: [ruledDraft('draft under a stalled frame')] });

    const result = await clearUserAuthorizedClaudeComposerDraft({
      port,
      wait: async () => undefined,
      settleMs: 250,
    });

    expect(result).toMatchObject({ status: 'failed', reason: 'clear_failed' });
    expect(port.sentKeys).toEqual(['Escape']);
    expect(port.log.map((entry) => entry.type)).toEqual(['capture', 'key', 'capture', 'capture', 'capture']);
  });

  it('never presses again over a composer whose text changed', async () => {
    const port = createFakeControlPort({
      captures: [ruledDraft('first words'), hintedDraft('first words and more typing')],
    });

    const result = await clearUserAuthorizedClaudeComposerDraft({
      port,
      wait: async () => undefined,
      settleMs: 0,
    });

    expect(result).toMatchObject({ status: 'refused', reason: 'draft_changed' });
    expect(port.sentKeys).toEqual(['Escape']);
  });

  it('does not press a second Escape when the hint was already armed before the first', async () => {
    const port = createFakeControlPort({
      captures: [hintedDraft('armed draft'), hintedDraft('armed draft')],
    });

    const result = await clearUserAuthorizedClaudeComposerDraft({
      port,
      wait: async () => undefined,
      settleMs: 0,
    });

    expect(result).toMatchObject({ status: 'failed', reason: 'clear_failed' });
    expect(port.sentKeys).toEqual(['Escape']);
  });

  describe('the pane\'s session clear-key ledger', () => {
    it('presses nothing while earlier clear keys still show no effect on the frame', async () => {
      const frame = ruledDraft('own paste the guard already pressed on');
      const clearKeys = createClaudeComposerClearKeyLedger({ stallBudgetMs: 135_000, nowMs: () => 0 });
      // The own-leftover guard pressed its pair onto this frame and Claude has not repainted.
      const frameText = parseClaudeScreenState(frame).text;
      clearKeys.recordPress(frameText);
      clearKeys.recordPress(frameText);
      const port = createFakeControlPort({ captures: [frame] });

      const result = await clearUserAuthorizedClaudeComposerDraft({
        port,
        clearKeys,
        wait: async () => undefined,
        settleMs: 0,
      });

      expect(result).toMatchObject({ status: 'refused', reason: 'unacknowledged_clear_keys' });
      expect(port.sentKeys).toEqual([]);
    });

    it('records its own Escapes so repeated requests over a frozen frame stay within the pair', async () => {
      const frame = ruledDraft('draft under a stalled frame');
      const clearKeys = createClaudeComposerClearKeyLedger({ stallBudgetMs: 135_000, nowMs: () => 0 });
      const port = createFakeControlPort({ captures: [frame] });
      const statuses: string[] = [];

      for (let request = 0; request < 3; request += 1) {
        const result = await clearUserAuthorizedClaudeComposerDraft({
          port,
          clearKeys,
          wait: async () => undefined,
          settleMs: 0,
        });
        statuses.push('reason' in result ? `${result.status}:${result.reason}` : result.status);
      }

      expect(statuses).toEqual([
        'failed:clear_failed',
        'failed:clear_failed',
        'refused:unacknowledged_clear_keys',
      ]);
      expect(port.sentKeys).toEqual(['Escape', 'Escape']);
    });
  });

  it('logs one info outcome with its evidence but never the composer text', async () => {
    const draft = 'my private half-typed thought';
    const infoFile = vi.spyOn(logger, 'infoFile').mockImplementation(() => undefined);
    try {
      const port = createFakeControlPort({ captures: [ruledDraft(draft), hintedDraft(draft), EMPTY_COMPOSER] });

      await clearUserAuthorizedClaudeComposerDraft({ port, wait: async () => undefined, settleMs: 0 });

      expect(infoFile.mock.calls).toEqual([
        ['[unified]: user-authorized composer clear outcome', {
          status: 'cleared',
          escapesSent: 2,
          escapeAgainToClearHintBefore: false,
          // The capture that justified the second Escape, not the final empty composer.
          escapeAgainToClearHintAfter: true,
          composerLength: draft.length,
        }],
      ]);
      expect(JSON.stringify(infoFile.mock.calls)).not.toContain(draft);
    } finally {
      infoFile.mockRestore();
    }
  });

  it('refuses to clear while Claude is generating because Escape would interrupt the turn', async () => {
    const port = createFakeControlPort({ captures: [generatingDraft('queued words')] });

    const result = await clearUserAuthorizedClaudeComposerDraft({
      port,
      wait: async () => undefined,
      settleMs: 0,
    });

    expect(result).toMatchObject({ status: 'refused', reason: 'generating' });
    expect(port.sentKeys).toEqual([]);
  });

  it.each([
    ['permission prompt', PERMISSION_PROMPT, 'permission_prompt'],
    ['unrecognized confirmation dialog', UNRECOGNIZED_DIALOG, 'unrecognized_confirmation_dialog'],
    ['unknown screen without composer', TRANSCRIPT_ONLY, 'no_interactive_composer'],
  ])('refuses to clear an unsafe %s', async (_name, capture, reason) => {
    const port = createFakeControlPort({ captures: [capture] });

    const result = await clearUserAuthorizedClaudeComposerDraft({
      port,
      wait: async () => undefined,
      settleMs: 0,
    });

    expect(result).toMatchObject({ status: 'refused', reason });
    expect(port.sentKeys).toEqual([]);
  });

  it('reports host_dead when capture fails before any keypress', async () => {
    const port = createFakeControlPort({
      captures: [idleDraft('unreachable')],
      failCaptureAtIndexes: [0],
    });

    const result = await clearUserAuthorizedClaudeComposerDraft({
      port,
      wait: async () => undefined,
      settleMs: 0,
    });

    expect(result).toMatchObject({ status: 'failed', reason: 'host_dead:unrecoverable' });
    expect(port.sentKeys).toEqual([]);
  });

  it('reports host_dead when recapture fails after Escape', async () => {
    const port = createFakeControlPort({
      captures: [idleDraft('draft to discard'), EMPTY_COMPOSER],
      failCaptureAtIndexes: [1],
    });

    const result = await clearUserAuthorizedClaudeComposerDraft({
      port,
      wait: async () => undefined,
      settleMs: 0,
    });

    expect(result).toMatchObject({ status: 'failed', reason: 'host_dead:unrecoverable' });
    expect(port.sentKeys).toEqual(['Escape']);
  });

  it('reports host_dead when Escape cannot be sent', async () => {
    const port = createFakeControlPort({
      captures: [idleDraft('draft to discard')],
      failSendKeys: ['Escape'],
    });

    const result = await clearUserAuthorizedClaudeComposerDraft({
      port,
      wait: async () => undefined,
      settleMs: 0,
    });

    expect(result).toMatchObject({ status: 'failed', reason: 'host_dead:unrecoverable' });
    expect(port.sentKeys).toEqual(['Escape']);
  });
});

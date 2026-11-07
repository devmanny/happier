import { describe, expect, it } from 'vitest';

import { createTurnAssistantTextSnapshotStore } from './createTurnAssistantTextSnapshotStore';

describe('TurnAssistantTextSnapshotStore', () => {
  it('returns root assistant text observed for the active turn token', () => {
    const store = createTurnAssistantTextSnapshotStore({ maxTextChars: 200 });
    const turnToken = store.beginTurn({ turnToken: 'turn-1', startSeqExclusive: 10 });

    store.observe({
      turnToken,
      text: '  The branch\n\nis ready.  ',
      source: 'ephemeral',
      seq: null,
      localId: 'assistant-1',
      sidechainId: null,
      provider: 'claude',
    });

    expect(store.getForTurn({ turnToken, startSeqExclusive: 10 })).toMatchObject({
      turnToken,
      // Raw formatting is kept for the notification formatter; only the ends are trimmed.
      text: 'The branch\n\nis ready.',
      source: 'ephemeral',
      seq: null,
      localId: 'assistant-1',
      sidechainId: null,
      provider: 'claude',
    });
  });

  it('does not reuse assistant text from another turn token', () => {
    const store = createTurnAssistantTextSnapshotStore({ maxTextChars: 200 });
    const firstTurn = store.beginTurn({ turnToken: 'turn-1', startSeqExclusive: 1 });
    store.observe({
      turnToken: firstTurn,
      text: 'Old response',
      source: 'committed',
      seq: 2,
      localId: 'old',
      sidechainId: null,
      provider: 'codex',
    });

    const secondTurn = store.beginTurn({ turnToken: 'turn-2', startSeqExclusive: 2 });

    expect(store.getForTurn({ turnToken: secondTurn, startSeqExclusive: 2 })).toBeNull();
  });

  it('prefers committed root assistant text over ephemeral text and ignores sidechains', () => {
    const store = createTurnAssistantTextSnapshotStore({ maxTextChars: 200 });
    const turnToken = store.beginTurn({ turnToken: 'turn-1', startSeqExclusive: 5 });

    store.observe({
      turnToken,
      text: 'Sidechain output',
      source: 'committed',
      seq: 8,
      localId: 'sidechain',
      sidechainId: 'task-1',
      provider: 'opencode',
    });
    store.observe({
      turnToken,
      text: 'Partial answer',
      source: 'ephemeral',
      seq: null,
      localId: 'assistant',
      sidechainId: null,
      provider: 'opencode',
    });
    store.observe({
      turnToken,
      text: 'Final answer',
      source: 'committed',
      seq: 9,
      localId: 'assistant',
      sidechainId: null,
      provider: 'opencode',
    });

    expect(store.getForTurn({ turnToken, startSeqExclusive: 5 })?.text).toBe('Final answer');
  });

  it('filters stale sequenced transcript text while allowing unsequenced live text', () => {
    const store = createTurnAssistantTextSnapshotStore({ maxTextChars: 200 });
    const turnToken = store.beginTurn({ turnToken: 'turn-1', startSeqExclusive: 20 });

    store.observe({
      turnToken,
      text: 'Previous turn response',
      source: 'transcript',
      seq: 20,
      localId: 'stale',
      sidechainId: null,
      provider: 'codex',
    });
    store.observe({
      turnToken,
      text: 'Current live response',
      source: 'ephemeral',
      seq: null,
      localId: 'live',
      sidechainId: null,
      provider: 'codex',
    });

    expect(store.getForTurn({ turnToken, startSeqExclusive: 20 })).toMatchObject({
      text: 'Current live response',
      seq: null,
      source: 'ephemeral',
    });
  });
});

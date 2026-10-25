import { describe, expect, it } from 'vitest';

import { createTurnInputKindTracker } from './turnInputKind';

describe('createTurnInputKindTracker', () => {
  it('flags a turn whose only input was automatic notices', () => {
    const tracker = createTurnInputKindTracker();
    tracker.recordDispatchedUserInput('[Happier automatic notice — child session event, not a user message]\nChild session: x');
    tracker.recordDispatchedUserInput('[Happier automatic notice — session nesting changed, not a user message]\nYou are now…');
    tracker.beginTurn('turn-1');

    expect(tracker.isAutomaticNoticeOnly('turn-1')).toBe(true);
  });

  it('does not flag a turn with any real user input, or with no recorded input', () => {
    const tracker = createTurnInputKindTracker();
    tracker.recordDispatchedUserInput('[Happier automatic notice — child session event, not a user message]\n…');
    tracker.recordDispatchedUserInput('please fix the test');
    tracker.beginTurn('turn-1');
    expect(tracker.isAutomaticNoticeOnly('turn-1')).toBe(false);

    tracker.beginTurn('turn-2');
    expect(tracker.isAutomaticNoticeOnly('turn-2')).toBe(false);
  });

  it('resets the input tally at each turn start and answers only for the active turn', () => {
    const tracker = createTurnInputKindTracker();
    tracker.recordDispatchedUserInput('[Happier automatic notice — child session event, not a user message]');
    tracker.beginTurn('turn-1');
    tracker.recordDispatchedUserInput('hello');
    tracker.beginTurn('turn-2');

    expect(tracker.isAutomaticNoticeOnly('turn-1')).toBe(false);
    expect(tracker.isAutomaticNoticeOnly('turn-2')).toBe(false);
    expect(tracker.isAutomaticNoticeOnly(null)).toBe(false);
  });
});

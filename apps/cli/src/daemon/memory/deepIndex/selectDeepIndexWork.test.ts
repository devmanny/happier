import { describe, expect, it } from 'vitest';

import { selectDeepIndexWork } from './selectDeepIndexWork';

describe('selectDeepIndexWork', () => {
  const candidateIds = ['a', 'b', 'c', 'd', 'e'];

  it('rotates fairly through the sessions that still have unread messages and skips the rest', () => {
    const pending = new Set(['a', 'c', 'e']);
    const first = selectDeepIndexWork({ candidateIds, startIndex: 0, priorityIds: [], maxSessions: 2, needsWork: (id) => pending.has(id) });
    expect(first.sessionIds).toEqual(['a', 'c']);
    const second = selectDeepIndexWork({ candidateIds, startIndex: first.nextStartIndex, priorityIds: [], maxSessions: 2, needsWork: (id) => pending.has(id) });
    expect(second.sessionIds).toEqual(['e', 'a']);
  });

  it('serves sessions with new activity before the history backfill', () => {
    const selection = selectDeepIndexWork({
      candidateIds,
      startIndex: 0,
      priorityIds: ['d', 'b'],
      maxSessions: 3,
      needsWork: () => true,
    });
    expect(selection.sessionIds).toEqual(['d', 'b', 'a']);
    expect(selection.consumedPriorityIds).toEqual(['d', 'b']);
  });

  it('drops priority entries that turned out to be caught up and selects nothing when all are', () => {
    const selection = selectDeepIndexWork({ candidateIds, startIndex: 3, priorityIds: ['b'], maxSessions: 2, needsWork: () => false });
    expect(selection).toEqual({ sessionIds: [], consumedPriorityIds: ['b'], nextStartIndex: 3 });
  });
});

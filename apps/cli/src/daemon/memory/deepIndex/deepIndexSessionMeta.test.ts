import { describe, expect, it } from 'vitest';

import { readDeepIndexSessionMeta } from './deepIndexSessionMeta';

describe('readDeepIndexSessionMeta', () => {
  it('titles a session like the session list does: summary, then name, then folder', () => {
    expect(readDeepIndexSessionMeta({ summary: { text: ' Relay migration ' }, name: 'ignored', flavor: 'claude' }))
      .toEqual({ title: 'Relay migration', agent: 'claude' });
    expect(readDeepIndexSessionMeta({ summaryText: 'Legacy summary', flavor: 'codex' })).toEqual({ title: 'Legacy summary', agent: 'codex' });
    expect(readDeepIndexSessionMeta({ name: 'Named', flavor: 'acp:opencode' })).toEqual({ title: 'Named', agent: 'acp:opencode' });
    expect(readDeepIndexSessionMeta({ path: '/Users/manny/Projects/happier/' })).toEqual({ title: 'happier', agent: null });
    expect(readDeepIndexSessionMeta({ path: 'C:\\Users\\manny\\repo' })).toEqual({ title: 'repo', agent: null });
  });

  it('knows nothing about a session whose metadata could not be read', () => {
    expect(readDeepIndexSessionMeta(null)).toEqual({ title: null, agent: null });
  });
});

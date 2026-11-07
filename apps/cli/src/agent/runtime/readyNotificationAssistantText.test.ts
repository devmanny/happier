import { describe, expect, it } from 'vitest';

import { resolveReadyNotificationAssistantText } from './readyNotificationAssistantText';

describe('resolveReadyNotificationAssistantText', () => {
  it('uses explicit assistant text before consulting the session snapshot', () => {
    const session = {
      getTurnAssistantTextSnapshot: () => ({
        turnToken: 'turn-1',
        text: 'Snapshot text',
        source: 'committed' as const,
        observedAtMs: 1,
        seq: 2,
        localId: 'snapshot',
        sidechainId: null,
        provider: 'codex',
      }),
    };

    expect(resolveReadyNotificationAssistantText({
      includeMessageText: true,
      explicitAssistantText: 'Explicit text',
      session,
      turnToken: 'turn-1',
      startSeqExclusive: 1,
    })).toBe('Explicit text');
  });

  it('falls back to the turn-scoped session snapshot when explicit text is empty', () => {
    const session = {
      getTurnAssistantTextSnapshot: (params: { turnToken?: string | null; startSeqExclusive?: number | null }) => {
        expect(params).toEqual({ turnToken: 'turn-1', startSeqExclusive: 10 });
        return {
          turnToken: 'turn-1',
          text: 'Snapshot text',
          source: 'committed' as const,
          observedAtMs: 1,
          seq: 11,
          localId: 'snapshot',
          sidechainId: null,
          provider: 'codex',
        };
      },
    };

    expect(resolveReadyNotificationAssistantText({
      includeMessageText: true,
      explicitAssistantText: '   ',
      session,
      turnToken: 'turn-1',
      startSeqExclusive: 10,
    })).toBe('Snapshot text');
  });

  it('respects the include-message setting over explicit and snapshot text', () => {
    const session = {
      getTurnAssistantTextSnapshot: () => {
        throw new Error('snapshot should not be read when message text is disabled');
      },
    };

    expect(resolveReadyNotificationAssistantText({
      includeMessageText: false,
      explicitAssistantText: 'Explicit text',
      session,
      turnToken: 'turn-1',
      startSeqExclusive: 1,
    })).toBeNull();
  });

  it('keeps the raw reply formatting for the notification formatter and cuts long text at a word boundary', () => {
    expect(resolveReadyNotificationAssistantText({
      includeMessageText: true,
      explicitAssistantText: '  ## Done\n\n- **one**\n- two  ',
    })).toBe('## Done\n\n- **one**\n- two');

    expect(resolveReadyNotificationAssistantText({
      includeMessageText: true,
      explicitAssistantText: 'alpha beta gamma delta',
      maxTextChars: 14,
    })).toBe('alpha beta…');
  });
});

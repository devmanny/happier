import { describe, expect, it } from 'vitest';

import { parseClaudeScreenState } from './tuiControls/screenState';
import { mapClaudeComposerClearResultToProtocolResult } from './runClaudeUnifiedTerminalSession';

describe('session.terminalComposer.clear wire result', () => {
  const screen = parseClaudeScreenState('❯ draft');

  it.each([
    ['draft_changed'],
    ['unacknowledged_clear_keys'],
  ] as const)('reports the %s refusal as not_safe with its internal reason as errorCode', (reason) => {
    expect(mapClaudeComposerClearResultToProtocolResult({ status: 'refused', reason, screen }, 's1')).toEqual({
      ok: false,
      status: 'not_safe',
      sessionId: 's1',
      errorCode: reason,
      error: `terminal_composer_clear_refused:${reason}`,
    });
  });
});

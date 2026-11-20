import { describe, expect, it } from 'vitest';

import { buildReadyNotificationContent } from './readyNotificationContent.js';

describe('buildReadyNotificationContent', () => {
  it('uses the session title and assistant preview when enabled', () => {
    expect(buildReadyNotificationContent({
      sessionTitle: 'Review branch',
      defaultTitle: 'Qwen Code',
      waitingForCommandLabel: 'Qwen Code',
      fallbackBody: 'Qwen Code is waiting for your command',
      includeMessageText: true,
      messageText: 'The branch is ready to review.',
    })).toEqual({
      title: 'Review branch',
      body: 'The branch is ready to review.',
      options: [],
    });
  });

  it('falls back to the waiting body when previews are disabled or empty', () => {
    expect(buildReadyNotificationContent({
      sessionTitle: 'Review branch',
      defaultTitle: 'Qwen Code',
      waitingForCommandLabel: 'Qwen Code',
      fallbackBody: 'Qwen Code is waiting for your command',
      includeMessageText: false,
      messageText: 'The branch is ready to review.',
    })).toEqual({
      title: 'Review branch',
      body: 'Qwen Code is waiting for your command',
      options: [],
    });

    expect(buildReadyNotificationContent({
      sessionTitle: '   ',
      defaultTitle: 'Qwen Code',
      waitingForCommandLabel: 'Qwen Code',
      fallbackBody: 'Qwen Code is waiting for your command',
      includeMessageText: true,
      messageText: '   ',
    })).toEqual({
      title: 'Qwen Code',
      body: 'Qwen Code is waiting for your command',
      options: [],
    });
  });

  it('formats the raw assistant message, returns its options and the agent as subtitle', () => {
    expect(buildReadyNotificationContent({
      sessionTitle: 'Checkout',
      defaultTitle: 'Codex',
      waitingForCommandLabel: 'Codex',
      fallbackBody: 'Codex is waiting for your command',
      agentName: 'Mateo',
      messageText: '## Ready\n\n**No charge was made.**\n\nMateo 🤖\n<options>\n<option>Buy it</option>\n<option>Cancel</option>\n</options>',
    })).toEqual({
      title: 'Checkout',
      subtitle: 'Mateo',
      body: 'Ready No charge was made.',
      options: ['Buy it', 'Cancel'],
    });
  });

  it('falls back to the waiting body and hides options when the message is disabled', () => {
    expect(buildReadyNotificationContent({
      defaultTitle: 'Codex',
      waitingForCommandLabel: 'Codex',
      fallbackBody: 'Codex is waiting for your command',
      includeMessageText: false,
      agentName: '  Mateo  ',
      messageText: 'Done <options><option>Yes</option></options>',
    })).toEqual({
      title: 'Codex',
      subtitle: 'Mateo',
      body: 'Codex is waiting for your command',
      options: [],
    });
  });
});

import { describe, expect, it } from 'vitest';

import type { RawJSONLines } from '../types';
import { isClaudeLocalCommandTranscriptMessage } from './isClaudeLocalCommandTranscriptMessage';

function userRow(content: string): RawJSONLines {
  return {
    type: 'user',
    message: { role: 'user', content },
    uuid: 'user-row',
    timestamp: '2026-07-02T16:37:57.447Z',
  } as unknown as RawJSONLines;
}

describe('isClaudeLocalCommandTranscriptMessage', () => {
  it('treats Claude local slash-command rows as transcript artifacts', () => {
    expect(isClaudeLocalCommandTranscriptMessage(userRow(
      '<command-name>/model</command-name>\n'
      + '<command-message>model</command-message>\n'
      + '<command-args></command-args>',
    ))).toBe(true);

    expect(isClaudeLocalCommandTranscriptMessage(userRow(
      '<command-name>/effort</command-name>\n'
      + '<command-message>effort</command-message>\n'
      + '<command-args></command-args>',
    ))).toBe(true);
  });

  it('treats Claude local command stdout rows as transcript artifacts', () => {
    expect(isClaudeLocalCommandTranscriptMessage(userRow(
      '<local-command-stdout>Set model to Opus 4.8 and saved as your default for new sessions</local-command-stdout>',
    ))).toBe(true);

    expect(isClaudeLocalCommandTranscriptMessage(userRow(
      '<local-command-stdout>Set effort level to low (saved as your default for new sessions)</local-command-stdout>',
    ))).toBe(true);

    expect(isClaudeLocalCommandTranscriptMessage(userRow([
      '<local-command-stdout>Set model to Opus 4.8 and saved as your default for new sessions',
      'Additional genuine multi-line Claude local-command stdout</local-command-stdout>',
    ].join('\n')))).toBe(true);
  });

  it('does not treat ordinary user text as a local command artifact', () => {
    expect(isClaudeLocalCommandTranscriptMessage(userRow('Please run the model benchmarks.'))).toBe(false);
  });

  it('preserves native shell input and output as visible transcript messages', () => {
    expect(isClaudeLocalCommandTranscriptMessage(userRow('<bash-input> echo hi</bash-input>'))).toBe(false);
    expect(isClaudeLocalCommandTranscriptMessage(userRow('<bash-stdout>hi\n</bash-stdout><bash-stderr></bash-stderr>'))).toBe(false);
  });

  // Shapes copied from a real Claude Code 2.1.319 JSONL (`/model` applied through the Agent SDK's
  // setModel, then replayed as user rows) plus the older `<command-message>`-first ordering that
  // Claude writes for skill commands.
  const caveat = '<local-command-caveat>The command below was run directly in Claude Code, not sent to you as a request, '
    + "and its output goes straight to the user. It's recorded here as context for later messages.</local-command-caveat>";
  const command = '<command-name>/model</command-name>\n            <command-message>model</command-message>\n'
    + '            <command-args>claude-opus-5-5</command-args>';
  const realRows: ReadonlyArray<readonly [string, string]> = [
    ['caveat', caveat],
    ['command', command],
    ['stdout', '<local-command-stdout>Set model to `claude-opus-5-5`</local-command-stdout>'],
    ['stderr', '<local-command-stderr>Model \'claude-nope\' not found</local-command-stderr>'],
    ['command-message first', '<command-message>superpowers:brainstorming</command-message>\n<command-name>/superpowers:brainstorming</command-name>'],
    ['command-args first', '<command-args>claude-opus-5-5</command-args>\n<command-name>/model</command-name>'],
  ];

  it.each(realRows)('treats the %s row as internal in string content form', (_label, text) => {
    expect(isClaudeLocalCommandTranscriptMessage({
      parentUuid: '653bce0f-fc94-4882-9e3e-77286e7e9a9e',
      isSidechain: false,
      promptId: '93280f79-d9a2-4889-801b-df503a9ae78b',
      type: 'user',
      message: { role: 'user', content: text },
      ...(text === caveat ? { isMeta: true } : {}),
      uuid: '13e24246-56e5-41a7-b488-f41209b68e9a',
      timestamp: '2026-11-09T03:45:49.761Z',
      userType: 'external',
      entrypoint: 'sdk-ts',
      sessionId: 'c4db504f-7c47-492c-884a-87ece7ea0955',
      version: '2.1.319',
    } as unknown as RawJSONLines)).toBe(true);
  });

  it.each(realRows)('treats the %s row as internal in content-array form (SDK replay)', (_label, text) => {
    expect(isClaudeLocalCommandTranscriptMessage({
      type: 'user',
      message: { role: 'user', content: [{ type: 'text', text }] },
      parent_tool_use_id: null,
      isReplay: true,
      uuid: '13e24246-56e5-41a7-b488-f41209b68e9a',
      session_id: 'c4db504f-7c47-492c-884a-87ece7ea0955',
    } as unknown as RawJSONLines)).toBe(true);
  });

  it('keeps ordinary prompts that merely mention a command tag visible', () => {
    expect(isClaudeLocalCommandTranscriptMessage(userRow('Why does Claude write <command-name> rows?'))).toBe(false);
  });
});


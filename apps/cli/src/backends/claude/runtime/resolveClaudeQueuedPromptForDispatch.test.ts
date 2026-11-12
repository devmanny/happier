import { describe, expect, it } from 'vitest';

import { resolveClaudeQueuedPromptForDispatch } from './resolveClaudeQueuedPromptForDispatch';

describe('resolveClaudeQueuedPromptForDispatch', () => {
  it('prefixes replaySeedV1 and retires it only once Claude accepted the prompt', async () => {
    const calls: string[] = [];
    let metadata: any = {};

    const sessionClient = {
      getMetadataSnapshot: () => metadata,
      refreshSessionSnapshotFromServerBestEffort: async () => {
        calls.push('refresh');
        metadata = {
          replaySeedV1: {
            v: 1,
            seedText: 'SEED',
            sourceSessionId: 'parent',
            sourceCutoffSeqInclusive: 3,
            createdAtMs: 123,
          },
        };
      },
      updateMetadata: async () => {
        calls.push('consume');
      },
    };

    const res = await resolveClaudeQueuedPromptForDispatch({
      sessionClient,
      batch: {
        message: 'hello',
        mode: { localId: 'local-1', replaySeedAllowed: true },
      },
      didBootstrap: false,
    });

    expect(res.didBootstrap).toBe(true);
    expect(res.message).toBe('SEED\n\nhello');
    expect(res.seedApplied).toBe(true);
    expect(calls).toEqual(['refresh']);

    await res.settleReplaySeedOnProviderAcceptance();
    expect(calls).toEqual(['refresh', 'consume']);
  });

  it('sends a slash command verbatim and keeps the replay seed for the next prompt', async () => {
    const seededClient = () => ({
      getMetadataSnapshot: () => ({
        replaySeedV1: { v: 1, seedText: 'SEED', sourceSessionId: 'parent', sourceCutoffSeqInclusive: 3, createdAtMs: 123 },
      }),
      updateMetadata: async () => {},
    });
    const dispatch = (message: string) => resolveClaudeQueuedPromptForDispatch({
      sessionClient: seededClient(),
      batch: { message, mode: { localId: 'local-1', replaySeedAllowed: true } },
      didBootstrap: true,
    });

    // Claude Code 2.1.322 (tmux probe, 11 nov 2026): `/name args` runs as a command, even an unknown
    // one; a leading path such as `/tmp/notes.txt …` is an ordinary prompt.
    const command = await dispatch('/effort high');
    expect(command).toMatchObject({ message: '/effort high', seedApplied: false });
    expect(await dispatch('/tmp/notes.txt summarize it')).toMatchObject({
      message: 'SEED\n\n/tmp/notes.txt summarize it',
      seedApplied: true,
    });
  });
});

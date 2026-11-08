import { describe, expect, it } from 'vitest';

import type { Metadata } from '@/api/types';

import { applyClaudeEffectiveModelUpdate } from './effectiveModelUpdate';

function client() {
  let metadata = {} as Metadata;
  const events: Array<{ event: unknown; id?: string }> = [];
  return {
    events,
    client: {
      sendSessionEvent: (event: unknown, id?: string) => { events.push({ event, id }); },
      updateMetadata: (updater: (m: Metadata) => Metadata) => { metadata = updater(metadata); },
      getMetadataSnapshot: () => metadata,
    },
  };
}

describe('applyClaudeEffectiveModelUpdate', () => {
  it('records an effort change the runtime applied, once, with the previous and new value', () => {
    const { client: c, events } = client();
    applyClaudeEffectiveModelUpdate({ client: c as never, modelId: 'claude-opus-5-5', reasoningEffort: 'high', source: 'sdk' as never, logPrefix: 't' });
    // The first observation is a baseline, not a change.
    expect(events).toEqual([]);
    applyClaudeEffectiveModelUpdate({ client: c as never, modelId: 'claude-opus-5-5', reasoningEffort: 'max', source: 'sdk' as never, logPrefix: 't' });
    applyClaudeEffectiveModelUpdate({ client: c as never, modelId: 'claude-opus-5-5', reasoningEffort: 'max', source: 'sdk' as never, logPrefix: 't' });
    expect(events).toHaveLength(1);
    expect(events[0]!.event).toMatchObject({
      type: 'runtime-config-outcome', status: 'applied', message: 'Effort changed to Max',
      changes: [{ key: 'reasoningEffort', previous: 'high', effective: 'max' }],
    });
  });
});

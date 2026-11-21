import { describe, expect, it } from 'vitest';

import type { Metadata } from '@/api/types';

import { applyClaudeEffectiveModelUpdate } from './effectiveModelUpdate';

function client() {
  let metadata = {} as Metadata;
  const events: Array<{ event: unknown; id?: string }> = [];
  return {
    events,
    setMetadata: (patch: Partial<Metadata>) => { metadata = { ...metadata, ...patch }; },
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

  it('identifies a model change by the override that requested it, so repeating a switch later records it again', () => {
    const { client: c, events, setMetadata } = client();
    const observe = (modelId: string) => applyClaudeEffectiveModelUpdate({ client: c as never, modelId, source: 'sdk' as never, logPrefix: 't' });
    observe('claude-haiku-5-5');
    for (const [updatedAt, modelId] of [[100, 'claude-sonnet-5-5'], [200, 'claude-haiku-5-5'], [300, 'claude-sonnet-5-5']] as const) {
      setMetadata({ modelOverrideV1: { v: 1, updatedAt, modelId } } as Partial<Metadata>);
      observe(modelId);
      // The provider reporting the same model again (a replay or retry) is the same change.
      observe(modelId);
    }

    expect(events.map((e) => (e.event as { changes: unknown }).changes)).toEqual([
      [{ key: 'model', previous: 'claude-haiku-5-5', effective: 'claude-sonnet-5-5' }],
      [{ key: 'model', previous: 'claude-sonnet-5-5', effective: 'claude-haiku-5-5' }],
      [{ key: 'model', previous: 'claude-haiku-5-5', effective: 'claude-sonnet-5-5' }],
    ]);
    expect(events.map((e) => e.id)).toEqual([
      'claude:model-changed:claude-haiku-5-5:claude-sonnet-5-5:at:100',
      'claude:model-changed:claude-sonnet-5-5:claude-haiku-5-5:at:200',
      'claude:model-changed:claude-haiku-5-5:claude-sonnet-5-5:at:300',
    ]);
  });

  it('identifies an effort change by the effort override that requested it', () => {
    const { client: c, events, setMetadata } = client();
    const observe = (reasoningEffort: string) => applyClaudeEffectiveModelUpdate({ client: c as never, modelId: 'claude-opus-5-5', reasoningEffort, source: 'sdk' as never, logPrefix: 't' });
    observe('high');
    setMetadata({ sessionConfigOptionOverridesV1: { v: 1, updatedAt: 400, overrides: { reasoning_effort: { updatedAt: 400, value: 'max' } } } } as Partial<Metadata>);
    observe('max');

    expect(events.map((e) => e.id)).toEqual(['claude:model-changed:claude-opus-5-5:claude-opus-5-5:effort:high:max:at:400']);
  });
});

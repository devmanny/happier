import { describe, expect, it } from 'vitest';

import { TranscriptRawAgentEventV1Schema } from '@happier-dev/protocol';

import { buildModelEffortChangeOutcome } from './modelEffortChangeOutcome';

const base = { provider: 'codex', runtime: 'codex-app-server' } as const;

describe('buildModelEffortChangeOutcome', () => {
  it('records a model and effort change the provider applied, as a runtime-config-outcome', () => {
    const event = buildModelEffortChangeOutcome({
      ...base,
      previous: { model: 'gpt-6', effort: 'medium' },
      applied: { model: 'gpt-6.1-sol', effort: 'high' },
      modelLabel: (id) => (id === 'gpt-6.1-sol' ? 'GPT 6.1 Sol' : id),
    });
    expect(event).toEqual({
      type: 'runtime-config-outcome',
      provider: 'codex',
      runtime: 'codex-app-server',
      status: 'applied',
      timing: 'current_window',
      message: 'Model changed to GPT 6.1 Sol · Effort High',
      changes: [
        { key: 'model', previous: 'gpt-6', effective: 'gpt-6.1-sol' },
        { key: 'reasoningEffort', previous: 'medium', effective: 'high' },
      ],
    });
    // Readers parse it with the canonical transcript schema.
    expect(TranscriptRawAgentEventV1Schema.safeParse(event).success).toBe(true);
  });

  it('names only what changed', () => {
    expect(buildModelEffortChangeOutcome({ ...base, previous: { model: 'm', effort: 'low' }, applied: { model: 'm', effort: 'xhigh' } })?.message)
      .toBe('Effort changed to Extra High');
    expect(buildModelEffortChangeOutcome({ ...base, previous: { model: 'a', effort: 'max' }, applied: { model: 'b', effort: 'max' } })?.changes)
      .toEqual([{ key: 'model', previous: 'a', effective: 'b' }]);
  });

  it('writes nothing when nothing changed or the previous value is not known yet', () => {
    expect(buildModelEffortChangeOutcome({ ...base, previous: { model: 'a', effort: 'high' }, applied: { model: 'a', effort: 'high' } })).toBeNull();
    expect(buildModelEffortChangeOutcome({ ...base, previous: { model: null, effort: null }, applied: { model: 'a', effort: 'high' } })).toBeNull();
  });
});

import type { TranscriptRawAgentEventV1 } from '@happier-dev/protocol';

export type ModelEffortChangeOutcomeEvent = Extract<TranscriptRawAgentEventV1, { type: 'runtime-config-outcome' }>;

type ModelEffort = Readonly<{ model?: string | null; effort?: string | null }>;

const EFFORT_LABELS: Record<string, string> = {
  minimal: 'Minimal',
  low: 'Low',
  medium: 'Medium',
  high: 'High',
  xhigh: 'Extra High',
  max: 'Max',
  ultra: 'Ultra',
};

export function effortLabel(effort: string): string {
  return EFFORT_LABELS[effort] ?? effort.charAt(0).toUpperCase() + effort.slice(1);
}

function changed(previous: string | null | undefined, applied: string | null | undefined): previous is string {
  return !!previous && !!applied && previous !== applied;
}

/**
 * The transcript record of a model or effort change the provider has applied (the one owner of
 * that line, for every provider): a `runtime-config-outcome` with the previous and new value of
 * what changed, and "Model changed to X · Effort High" (or only the part that changed). Null when
 * nothing changed, or when the previous value isn't known yet (a session's first observation).
 */
export function buildModelEffortChangeOutcome(params: Readonly<{
  provider: string;
  runtime: string;
  previous: ModelEffort;
  applied: ModelEffort;
  modelLabel?: (modelId: string) => string;
}>): ModelEffortChangeOutcomeEvent | null {
  const changes: NonNullable<ModelEffortChangeOutcomeEvent['changes']> = [];
  const parts: string[] = [];
  const model = params.applied.model;
  const effort = params.applied.effort;
  if (changed(params.previous.model, model) && model) {
    changes.push({ key: 'model', previous: params.previous.model, effective: model });
    parts.push(`Model changed to ${params.modelLabel?.(model) ?? model}`);
  }
  if (changed(params.previous.effort, effort) && effort) {
    changes.push({ key: 'reasoningEffort', previous: params.previous.effort, effective: effort });
    parts.push(parts.length > 0 ? `Effort ${effortLabel(effort)}` : `Effort changed to ${effortLabel(effort)}`);
  }
  if (changes.length === 0) return null;
  return {
    type: 'runtime-config-outcome',
    provider: params.provider,
    runtime: params.runtime,
    status: 'applied',
    timing: 'current_window',
    message: parts.join(' · '),
    changes,
  };
}

import type { reconcileClaudeSessionModelsState } from './reconcileClaudeSessionModelsState';
import type { Metadata } from '@/api/types';
import { updateMetadataBestEffort } from '@/api/session/sessionWritesBestEffort';
import { buildModelEffortChangeOutcome, type ModelEffortChangeOutcomeEvent } from '@/agent/runtime/configChange/modelEffortChangeOutcome';
import { resolveModelOverrideFromMetadataSnapshot } from '@/agent/runtime/permission/permissionModeFromMetadata';
import { resolveSessionConfigOptionOverridesFromMetadataSnapshot } from '@/agent/runtime/sessionConfigOptionOverrideSync';

import { buildClaudeSessionModelsMetadataWithCurrentModelId } from '../remote/buildClaudeSessionModelsMetadataFromSupportedModels';

export type ClaudeEffectiveModelUpdateSource = 'statusline' | 'transcript' | 'sdk' | 'control';
export type ClaudeEffectiveModelObservation = Readonly<{ modelId: string; reasoningEffort: string }>;

type ClaudeEffectiveModelUpdateClient = Readonly<{
  sendSessionEvent(event: ModelEffortChangeOutcomeEvent, id?: string): void;
  updateMetadata(updater: (metadata: Metadata) => Metadata): void | Promise<void>;
  getMetadataSnapshot?: () => Metadata | null;
}>;

type EffectiveModelState = {
  lastSeenModelId: string | null;
  lastSeenEffort: string | null;
  lastMetadataRequestKey: string | null;
  lastEmittedTransitionKey: string | null;
};

const stateByClient = new WeakMap<object, EffectiveModelState>();

function stateFor(client: object): EffectiveModelState {
  const existing = stateByClient.get(client);
  if (existing) return existing;
  const created: EffectiveModelState = {
    lastSeenModelId: null,
    lastSeenEffort: null,
    lastMetadataRequestKey: null,
    lastEmittedTransitionKey: null,
  };
  stateByClient.set(client, created);
  return created;
}

function readString(value: unknown): string | null {
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : null;
}

function readPositiveTokens(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? Math.trunc(value) : null;
}

type SessionModelsState = NonNullable<Metadata['sessionModelsV1']>;
type SessionModelEntry = NonNullable<SessionModelsState['availableModels']>[number];

function readClaudeSessionModelsState(metadata: Metadata | null | undefined): SessionModelsState | null {
  const primary = metadata?.sessionModelsV1;
  if (primary?.provider === 'claude') return primary;
  const legacy = metadata?.acpSessionModelsV1;
  if (legacy?.provider === 'claude') return legacy;
  return null;
}

function readActiveClaudeModelId(metadata: Metadata | null | undefined): string | null {
  return readString(readClaudeSessionModelsState(metadata)?.currentModelId);
}

function findSessionModelEntry(
  metadata: Metadata | null | undefined,
  modelId: string,
): SessionModelEntry | null {
  const state = readClaudeSessionModelsState(metadata);
  const entries = Array.isArray(state?.availableModels) ? state.availableModels : [];
  return entries.find((entry) => entry.id === modelId) ?? null;
}

function hasRequestedModelDetails(params: Readonly<{
  metadata: Metadata | null | undefined;
  modelId: string;
  displayName: string | null;
  contextWindowTokens: number | null;
  reasoningEffort: string | null;
}>): boolean {
  if (params.displayName === null && params.contextWindowTokens === null && params.reasoningEffort === null) return true;
  const entry = findSessionModelEntry(params.metadata, params.modelId);
  if (!entry) return false;
  if (params.displayName !== null && entry.name !== params.displayName) return false;
  if (params.contextWindowTokens !== null && entry.contextWindowTokens !== params.contextWindowTokens) return false;
  const effortOption = entry.modelOptions?.find(option => option.id === 'reasoning_effort');
  if (params.reasoningEffort !== null && effortOption && effortOption.currentValue !== params.reasoningEffort) return false;
  return true;
}

function readMetadataSnapshot(client: ClaudeEffectiveModelUpdateClient): Metadata | null {
  try {
    return client.getMetadataSnapshot?.() ?? null;
  } catch {
    return null;
  }
}

function buildMetadataRequestKey(params: Readonly<{
  modelId: string;
  displayName: string | null;
  contextWindowTokens: number | null;
  reasoningEffort: string | null;
}>): string {
  return `${params.modelId}|${params.displayName ?? ''}|${params.contextWindowTokens ?? ''}|${params.reasoningEffort ?? ''}`;
}

/**
 * The change's identity is the request it applied: the model/effort override's `updatedAt` when the
 * applied value is what that override asks for. Retries and replays of one change keep its id (the
 * transcript insertion dedupes them); the same switch requested again later is a new line. A change
 * no override asked for (e.g. `/model` typed in the terminal) keeps the from/to identity.
 */
function buildModelChangedEventId(params: Readonly<{
  fromModelId: string;
  toModelId: string;
  fromEffort?: string | null;
  toEffort?: string | null;
  modelRequestedAt: number | null;
  effortRequestedAt: number | null;
}>): string {
  const modelChanged = params.fromModelId !== params.toModelId;
  const effortChanged = !!params.fromEffort && !!params.toEffort && params.fromEffort !== params.toEffort;
  const modelAt = modelChanged && params.modelRequestedAt !== null ? `:at:${params.modelRequestedAt}` : '';
  const effort = effortChanged
    ? `:effort:${encodeURIComponent(params.fromEffort!)}:${encodeURIComponent(params.toEffort!)}${params.effortRequestedAt !== null ? `:at:${params.effortRequestedAt}` : ''}`
    : '';
  return `claude:model-changed:${encodeURIComponent(params.fromModelId)}:${encodeURIComponent(params.toModelId)}${modelAt}${effort}`;
}

function readModelRequestedAt(metadata: Metadata | null | undefined, modelId: string): number | null {
  const override = resolveModelOverrideFromMetadataSnapshot({ metadata });
  return override && override.modelId === modelId ? override.updatedAt : null;
}

function readEffortRequestedAt(metadata: Metadata | null | undefined, effort: string | null): number | null {
  if (!effort) return null;
  const newest = resolveSessionConfigOptionOverridesFromMetadataSnapshot({ metadata })
    .filter((override) => override.configId === 'reasoning_effort')
    .at(-1);
  return newest && newest.valueId.toLowerCase() === effort.toLowerCase() ? newest.updatedAt : null;
}

function resolveModelLabel(params: Readonly<{
  metadata: Metadata | null | undefined;
  modelId: string;
  displayName: string | null;
}>): string {
  return params.displayName ?? readString(findSessionModelEntry(params.metadata, params.modelId)?.name) ?? params.modelId;
}

export function applyClaudeEffectiveModelUpdate(params: Readonly<{
  client: ClaudeEffectiveModelUpdateClient;
  reconcileModels?: typeof reconcileClaudeSessionModelsState;
  modelId: string;
  displayName?: string | null;
  contextWindowTokens?: number | null;
  reasoningEffort?: string | null;
  source: ClaudeEffectiveModelUpdateSource;
  logPrefix: string;
}>): void {
  const modelId = readString(params.modelId);
  if (!modelId) return;

  const displayName = readString(params.displayName);
  const contextWindowTokens = readPositiveTokens(params.contextWindowTokens);
  const reasoningEffort = readString(params.reasoningEffort);
  const metadataSnapshot = readMetadataSnapshot(params.client);
  const state = stateFor(params.client);
  const previousModelId = readActiveClaudeModelId(metadataSnapshot) ?? state.lastSeenModelId;
  const metadataRequestKey = buildMetadataRequestKey({ modelId, displayName, contextWindowTokens, reasoningEffort });

  const alreadyAppliedInMemory = state.lastSeenModelId === modelId;
  const shouldUpdateMetadata =
    (!alreadyAppliedInMemory && previousModelId !== modelId)
    || !hasRequestedModelDetails({ metadata: metadataSnapshot, modelId, displayName, contextWindowTokens, reasoningEffort });
  // Even when metadata already matches, record the live observation in the session's source
  // contributions so a later catalog/SDK publication cannot replace it with a catalog estimate.
  if (!shouldUpdateMetadata && params.reconcileModels) {
    buildClaudeSessionModelsMetadataWithCurrentModelId({
      currentModelId: modelId,
      metadata: metadataSnapshot,
      reconcileModels: params.reconcileModels,
      currentModel: {
        ...(displayName ? { name: displayName } : {}),
        ...(contextWindowTokens !== null ? { contextWindowTokens } : {}),
        ...(reasoningEffort ? { reasoningEffort } : {}),
      },
    });
  }
  if (shouldUpdateMetadata && state.lastMetadataRequestKey !== metadataRequestKey) {
    state.lastMetadataRequestKey = metadataRequestKey;
    updateMetadataBestEffort(
      params.client,
      (metadata) => ({
        ...metadata,
        ...(buildClaudeSessionModelsMetadataWithCurrentModelId({
          currentModelId: modelId,
          reconcileModels: params.reconcileModels,
          metadata,
          currentModel: {
            ...(displayName ? { name: displayName } : {}),
            ...(contextWindowTokens !== null ? { contextWindowTokens } : {}),
            ...(reasoningEffort ? { reasoningEffort } : {}),
          },
        }) ?? {}),
      }),
      params.logPrefix,
      'runtime_model_update',
    );
  }

  // What the runtime reports it runs with is what was applied: a change from what it ran with
  // before is recorded once (model and effort; only what changed).
  const previousEffort = state.lastSeenEffort;
  const event = buildModelEffortChangeOutcome({
    provider: 'claude',
    runtime: 'claude',
    previous: { model: previousModelId, effort: previousEffort },
    applied: { model: modelId, effort: reasoningEffort ?? previousEffort },
    modelLabel: (id) => resolveModelLabel({ metadata: metadataSnapshot, modelId: id, displayName }),
  });
  if (event && previousModelId) {
    const transitionKey = `${previousModelId}\u0000${modelId}\u0000${previousEffort ?? ''}\u0000${reasoningEffort ?? ''}`;
    if (state.lastEmittedTransitionKey !== transitionKey) {
      state.lastEmittedTransitionKey = transitionKey;
      params.client.sendSessionEvent(
        event,
        buildModelChangedEventId({
          fromModelId: previousModelId,
          toModelId: modelId,
          fromEffort: previousEffort,
          toEffort: reasoningEffort,
          modelRequestedAt: readModelRequestedAt(metadataSnapshot, modelId),
          effortRequestedAt: readEffortRequestedAt(metadataSnapshot, reasoningEffort),
        }),
      );
    }
  }

  state.lastSeenModelId = modelId;
  if (reasoningEffort) state.lastSeenEffort = reasoningEffort;
}

import type {
  SessionProviderInputRejectedBeforeEffectReason,
  SessionProviderInputOutcomeObserver,
  SessionProviderInputOutcomeProducer,
} from '@/api/session/sessionClient';
import { readNonBlankOpaqueIdentifier } from '@/utils/opaqueIdentifiers';
import { readPendingLocalId } from '@happier-dev/protocol';
import { readClaudeActiveUnifiedTerminalHost } from '../utils/readClaudeActiveTerminalMode';

function createClaudeUnifiedProviderInputProducer(
  isCurrentRuntimeMode?: (() => boolean) | undefined,
): SessionProviderInputOutcomeProducer {
  return Object.freeze({
    providerId: 'claude',
    mode: 'unifiedTerminal',
    matchesCurrentSession: ({ metadata }) => {
      const flavor = metadata && typeof metadata === 'object'
        ? readNonBlankOpaqueIdentifier((metadata as Record<string, unknown>).flavor)
        : null;
      return (flavor === null || flavor === 'claude')
        && (isCurrentRuntimeMode?.() ?? readClaudeActiveUnifiedTerminalHost({ metadata }) !== null);
    },
  });
}

type ProviderOutcomeBindingClient = Readonly<{
  bindProviderInputOutcomeProducer?: (
    producer: SessionProviderInputOutcomeProducer,
  ) => SessionProviderInputOutcomeObserver;
}>;

type ClaudeUnifiedProviderInputIdentity = Readonly<{
  userMessageLocalIds: readonly string[];
  appliedModelId?: string | null;
}>;

export type ClaudeUnifiedProviderInputOutcomeBridge = Readonly<{
  observeAccepted: (input: ClaudeUnifiedProviderInputIdentity) => boolean;
  observeEffectMayHaveOccurred: (input: ClaudeUnifiedProviderInputIdentity) => boolean;
  /** Written and submitted to Claude, acceptance not yet proven: a provider effect is possible. */
  observeCustody: (input: ClaudeUnifiedProviderInputIdentity) => boolean;
  observeRejectedBeforeEffect: (
    input: ClaudeUnifiedProviderInputIdentity & Readonly<{ reason: SessionProviderInputRejectedBeforeEffectReason }>,
  ) => boolean;
}>;

function readExactIdentity(input: ClaudeUnifiedProviderInputIdentity): Readonly<{ localId: string }> | null {
  if (input.userMessageLocalIds.length !== 1) return null;
  const localId = readPendingLocalId(input.userMessageLocalIds[0]);
  if (localId === null) return null;
  return { localId };
}

export function createClaudeUnifiedProviderInputOutcomeBridge(
  client: object,
  options?: Readonly<{ isCurrentRuntimeMode?: (() => boolean) | undefined }>,
): ClaudeUnifiedProviderInputOutcomeBridge {
  const bindingClient = client as ProviderOutcomeBindingClient;
  const observe = bindingClient.bindProviderInputOutcomeProducer?.(
    createClaudeUnifiedProviderInputProducer(options?.isCurrentRuntimeMode),
  ) ?? null;
  const observeExact = (
    input: ClaudeUnifiedProviderInputIdentity,
    emit: (observer: SessionProviderInputOutcomeObserver, identity: NonNullable<ReturnType<typeof readExactIdentity>>) => void,
  ): boolean => {
    if (!observe) return false;
    const identity = readExactIdentity(input);
    if (!identity) return false;
    emit(observe, identity);
    return true;
  };

  return Object.freeze({
    observeAccepted: (input) => observeExact(input, (observer, identity) => {
      const appliedModelId = readNonBlankOpaqueIdentifier(input.appliedModelId);
      observer({
        kind: 'accepted',
        ...identity,
        ...(appliedModelId ? { appliedModelId } : {}),
      });
    }),
    observeEffectMayHaveOccurred: (input) => observeExact(input, (observer, identity) => {
      observer({ kind: 'effect_may_have_occurred', ...identity });
    }),
    observeCustody: (input) => observeExact(input, (observer, identity) => {
      observer({ kind: 'custody_observed', ...identity });
    }),
    observeRejectedBeforeEffect: (input) => observeExact(input, (observer, identity) => {
      observer({ kind: 'rejected_before_effect', ...identity, reason: input.reason });
    }),
  });
}

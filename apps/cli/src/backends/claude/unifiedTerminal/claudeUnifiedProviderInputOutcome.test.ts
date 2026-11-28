import { describe, expect, it, vi } from 'vitest';

import { createClaudeUnifiedProviderInputOutcomeBridge } from './claudeUnifiedProviderInputOutcome';
import type { SessionProviderInputOutcomeProducer } from '@/api/session/sessionClient';
import type { Metadata } from '@/api/types';

describe('createClaudeUnifiedProviderInputOutcomeBridge', () => {
  it('preserves one exact opaque local id for accepted and pre-effect rejected evidence', () => {
    const observe = vi.fn();
    const bindProviderInputOutcomeProducer = vi.fn((_producer: SessionProviderInputOutcomeProducer) => observe);
    const bridge = createClaudeUnifiedProviderInputOutcomeBridge({ bindProviderInputOutcomeProducer });

    expect(bridge.observeAccepted({
      userMessageLocalIds: [' exact-local-id '],
    })).toBe(true);
    expect(bridge.observeAccepted({
      userMessageLocalIds: ['   '],
    })).toBe(false);
    expect(bridge.observeEffectMayHaveOccurred({
      userMessageLocalIds: ['uncertain-local-id'],
    })).toBe(true);
    expect(bridge.observeRejectedBeforeEffect({
      userMessageLocalIds: ['rejected-local-id'],
      reason: 'provider_rejected_before_acceptance',
    })).toBe(true);
    expect(bridge.observeCustody({
      userMessageLocalIds: ['submitted-local-id'],
    })).toBe(true);
    expect(bridge.observeCustody({ userMessageLocalIds: ['a', 'b'] })).toBe(false);

    expect(bindProviderInputOutcomeProducer).toHaveBeenCalledWith(expect.objectContaining({
      providerId: 'claude',
      mode: 'unifiedTerminal',
      matchesCurrentSession: expect.any(Function),
    }));
    const producer = bindProviderInputOutcomeProducer.mock.calls[0]?.[0];
    expect(producer?.matchesCurrentSession({
      metadata: { flavor: 'claude', terminal: { mode: 'tmux' } } as Metadata,
    })).toBe(true);
    expect(producer?.matchesCurrentSession({
      metadata: { terminal: { mode: 'zellij' } } as Metadata,
    })).toBe(true);
    expect(producer?.matchesCurrentSession({
      metadata: { flavor: 'claude', terminal: { mode: 'plain' } } as Metadata,
    })).toBe(false);
    expect(producer?.matchesCurrentSession({
      metadata: { flavor: 'codex', terminal: { mode: 'tmux' } } as Metadata,
    })).toBe(false);
    expect(observe.mock.calls).toEqual([
      [{ kind: 'accepted', localId: ' exact-local-id ' }],
      [{ kind: 'effect_may_have_occurred', localId: 'uncertain-local-id' }],
      [{
        kind: 'rejected_before_effect',
        localId: 'rejected-local-id',
        reason: 'provider_rejected_before_acceptance',
      }],
      [{ kind: 'custody_observed', localId: 'submitted-local-id' }],
    ]);
  });

  it('fails closed when provider evidence does not identify exactly one local input', () => {
    const observe = vi.fn();
    const bridge = createClaudeUnifiedProviderInputOutcomeBridge({
      bindProviderInputOutcomeProducer: () => observe,
    });

    expect(bridge.observeAccepted({ userMessageLocalIds: [] })).toBe(false);
    expect(bridge.observeAccepted({ userMessageLocalIds: ['a', 'b'] })).toBe(false);
    expect(bridge.observeAccepted({ userMessageLocalIds: [''] })).toBe(false);
    expect(bridge.observeAccepted({ userMessageLocalIds: ['   '] })).toBe(false);
    expect(observe).not.toHaveBeenCalled();
  });

  it('fails closed when the session client has no typed outcome binding', () => {
    const bridge = createClaudeUnifiedProviderInputOutcomeBridge({});

    expect(bridge.observeAccepted({
      userMessageLocalIds: ['exact-local'],
    })).toBe(false);
  });

  it('lets the active launcher runtime control veto an otherwise matching Claude terminal session', () => {
    const bindProviderInputOutcomeProducer = vi.fn((_producer: SessionProviderInputOutcomeProducer) => vi.fn());
    createClaudeUnifiedProviderInputOutcomeBridge(
      { bindProviderInputOutcomeProducer },
      { isCurrentRuntimeMode: () => false },
    );

    const producer = bindProviderInputOutcomeProducer.mock.calls[0]?.[0];
    expect(producer?.matchesCurrentSession({
      metadata: { flavor: 'claude', terminal: { mode: 'tmux' } } as Metadata,
    })).toBe(false);
  });
});

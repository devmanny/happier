import { afterEach, describe, expect, it, vi } from 'vitest';

import type { TerminalPromptInput } from '@/agent/runtime/terminal/_types';

import type { ClaudeUnifiedComposerDraftGuardOutcome } from './createClaudeUnifiedPromptInjector';
import { createClaudeUnifiedInputArbiter } from './createClaudeUnifiedInputArbiter';
import { createClaudeUnifiedPendingQueuePump } from './createClaudeUnifiedPendingQueuePump';
import { createClaudeUnifiedPromptInjector } from './createClaudeUnifiedPromptInjector';

/** Server read latency of the session client's pending-queue reconcile (one HTTP round trip). */
const RECONCILE_LATENCY_MS = 50;

/**
 * The session client's pending-queue boundary: a forced reconcile is a server read, and the
 * explicit wake publishes an eligibility update once that read settles (sessionClient
 * wakePendingMaterialization).
 */
function createPendingDeliveryStateServer() {
  const waiters = new Set<(changed: boolean) => void>();
  let reconciles = 0;
  const reconcilePendingQueueState = async (): Promise<boolean> => {
    reconciles += 1;
    await new Promise((resolve) => setTimeout(resolve, RECONCILE_LATENCY_MS));
    return false;
  };
  return {
    readReconciles: () => reconciles,
    reconcilePendingQueueState,
    waitForPendingEligibilityUpdate: (signal?: AbortSignal) => new Promise<boolean>((resolve) => {
      if (signal?.aborted) return resolve(false);
      const waiter = (changed: boolean) => {
        waiters.delete(waiter);
        resolve(changed);
      };
      waiters.add(waiter);
      signal?.addEventListener('abort', () => waiter(false), { once: true });
    }),
    wakePendingMaterialization: () => {
      void reconcilePendingQueueState().finally(() => {
        for (const waiter of [...waiters]) waiter(true);
      });
    },
  };
}

async function runPendingHeadAgainstHost(params: Readonly<{
  guardOutcomes: (pass: number) => ClaudeUnifiedComposerDraftGuardOutcome['status'];
  windowMs: number;
}>) {
  const server = createPendingDeliveryStateServer();
  let guardPasses = 0;
  const onDraftGuardClear = vi.fn(() => server.wakePendingMaterialization());
  const injector = createClaudeUnifiedPromptInjector({
    inputInjection: {
      hostKind: 'tmux',
      // The host adapter's own quiet-screen gate: the composer is empty, but the pane is not
      // quiet yet, so the write is deferred for the adapter's quiet period.
      injectUserPrompt: async (input: TerminalPromptInput) => ({
        status: 'deferred' as const,
        reason: 'user_typing' as const,
        retryAfterMs: input.scheduling?.deferredUntilQuietMs,
      }),
    },
    composerDraftGuard: async () => {
      guardPasses += 1;
      return { status: params.guardOutcomes(guardPasses) };
    },
    onDraftGuardClear,
  });
  const arbiter = createClaudeUnifiedInputArbiter({
    quietPeriodMs: 0,
    injectPrompt: injector.injectPrompt,
  });
  arbiter.observeLifecycle({ type: 'turn_state', state: 'idle', observedAtMs: Date.now() });
  arbiter.observeLifecycle({ type: 'output', observedAtMs: Date.now() });
  let delivered = false;
  const pump = createClaudeUnifiedPendingQueuePump({
    inputConsumer: {
      waitForNextInput: async ({ abortSignal }) => {
        if (!delivered) {
          delivered = true;
          return { message: 'queued from the phone', mode: undefined, isolate: false, hash: 'h1', userMessageLocalIds: ['local-1'] };
        }
        return await new Promise((resolve) => {
          abortSignal?.addEventListener('abort', () => resolve(null), { once: true });
        });
      },
    },
    pendingDeliveryState: server,
    arbiter,
  });
  const abortController = new AbortController();
  const running = pump.start({ abortSignal: abortController.signal });
  await vi.advanceTimersByTimeAsync(params.windowMs);
  const observed = { guardPasses, reconciles: server.readReconciles(), wakes: onDraftGuardClear.mock.calls.length };
  abortController.abort();
  pump.dispose();
  arbiter.dispose();
  await vi.advanceTimersByTimeAsync(RECONCILE_LATENCY_MS);
  await running;
  return observed;
}

describe('createClaudeUnifiedPromptInjector draft-guard clear wake', () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  // A guard pass that finds no draft woke Pending on every pass, before the host write. When the
  // host then deferred (pane not quiet, pane initializing), the wake re-ran the paused pump at once:
  // reconcile, drain, guard, wake again, bypassing the adapter's 800 ms quiet retry.
  it('does not wake Pending on every clean guard pass while the host keeps deferring the write', async () => {
    vi.useFakeTimers();
    const windowMs = 4_000;

    const observed = await runPendingHeadAgainstHost({ guardOutcomes: () => 'no_draft', windowMs });

    // One pass from the pump, one from its paused reconcile, then one per 800 ms quiet retry.
    expect(observed.guardPasses).toBeLessThanOrEqual(2 + Math.ceil(windowMs / 800));
    expect(observed.reconciles).toBeLessThanOrEqual(2);
    expect(observed.wakes).toBe(0);
  });

  it('wakes Pending once when a pass ends a draft-guard deferral episode', async () => {
    vi.useFakeTimers();

    const observed = await runPendingHeadAgainstHost({
      guardOutcomes: (pass) => (pass <= 2 ? 'foreign_draft' : 'no_draft'),
      windowMs: 6_000,
    });

    expect(observed.wakes).toBe(1);
    expect(observed.guardPasses).toBeGreaterThan(3);
  });
});

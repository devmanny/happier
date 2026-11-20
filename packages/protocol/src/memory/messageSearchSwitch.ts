import { z } from 'zod';

import { MemorySearchCoverageV2Schema, type MemorySearchCoverageV2 } from './memorySearch.js';
import type { MemorySettingsV1 } from './memorySettings.js';

/**
 * Conversation search on one machine: whether its daemon keeps the full-text index of the
 * account's conversations and answers `daemon.memory.search` v2. It lives in that machine's
 * memory settings (the canonical machine-local owner): on means memory on with the deep index
 * over the whole history. A machine that never turned it on has it off (`enabled` defaults false).
 */
export function isMessageSearchEnabled(settings: Pick<MemorySettingsV1, 'enabled' | 'indexMode'>): boolean {
  return settings.enabled === true && settings.indexMode === 'deep';
}

/** The machine's memory settings with conversation search switched; its other choices stay. */
export function applyMessageSearchSwitch(settings: MemorySettingsV1, enabled: boolean): MemorySettingsV1 {
  return enabled
    ? { ...settings, enabled: true, indexMode: 'deep', backfillPolicy: 'all_history' }
    : { ...settings, enabled: false };
}

/** `daemon.memory.messageSearch.set`: `deleteIndex` (with `enabled: false`) also removes the local index. */
export const MessageSearchSetRequestV1Schema = z.object({
  v: z.literal(1),
  enabled: z.boolean(),
  deleteIndex: z.boolean().default(false),
}).passthrough();
export type MessageSearchSetRequestV1 = z.infer<typeof MessageSearchSetRequestV1Schema>;

/** `daemon.memory.messageSearch.status` (and the answer to `.set`). */
export const MessageSearchStatusV1Schema = z.object({
  v: z.literal(1),
  enabled: z.boolean(),
  /** `indexing` while the history backfill still has sessions to read. */
  state: z.enum(['off', 'indexing', 'ready']),
  coverage: MemorySearchCoverageV2Schema.nullable(),
  /** Size of the local index file; null when there is none. */
  indexBytes: z.number().int().nonnegative().nullable(),
}).passthrough();
export type MessageSearchStatusV1 = z.infer<typeof MessageSearchStatusV1Schema>;

/** Share of the known sessions the index has read up to their latest message (0…1). */
export function messageSearchProgress(coverage: MemorySearchCoverageV2 | null): number {
  if (!coverage || coverage.knownSessionCount <= 0) return 0;
  const read = Math.max(0, coverage.knownSessionCount - coverage.pendingSessionCount);
  return Math.min(1, read / coverage.knownSessionCount);
}

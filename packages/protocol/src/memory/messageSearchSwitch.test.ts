import { describe, expect, it } from 'vitest';

import { DEFAULT_MEMORY_SETTINGS, normalizeMemorySettings } from './memorySettings.js';
import {
  applyMessageSearchSwitch,
  isMessageSearchEnabled,
  MessageSearchSetRequestV1Schema,
  MessageSearchStatusV1Schema,
  messageSearchProgress,
} from './messageSearchSwitch.js';

describe('message search switch (per machine)', () => {
  it('is off on a machine that never turned it on', () => {
    expect(isMessageSearchEnabled(DEFAULT_MEMORY_SETTINGS)).toBe(false);
    expect(isMessageSearchEnabled({ ...DEFAULT_MEMORY_SETTINGS, enabled: true, indexMode: 'hints' })).toBe(false);
  });

  it('turns on the full-text index over the whole history and keeps the machine’s other choices', () => {
    const current = normalizeMemorySettings({ v: 1, enabled: false, indexMode: 'hints', budgets: { maxDiskMbDeep: 3000 } });
    const on = applyMessageSearchSwitch(current, true);
    expect(on).toMatchObject({ enabled: true, indexMode: 'deep', backfillPolicy: 'all_history', budgets: { maxDiskMbDeep: 3000 } });
    expect(isMessageSearchEnabled(on)).toBe(true);

    const off = applyMessageSearchSwitch(on, false);
    expect(off).toMatchObject({ enabled: false, indexMode: 'deep', budgets: { maxDiskMbDeep: 3000 } });
    expect(isMessageSearchEnabled(off)).toBe(false);
  });

  it('only deletes the local index when asked to', () => {
    expect(MessageSearchSetRequestV1Schema.parse({ v: 1, enabled: false })).toEqual({ v: 1, enabled: false, deleteIndex: false });
    expect(MessageSearchSetRequestV1Schema.parse({ v: 1, enabled: false, deleteIndex: true }).deleteIndex).toBe(true);
    expect(MessageSearchSetRequestV1Schema.safeParse({ v: 1 }).success).toBe(false);
  });

  it('reports how far the history backfill got', () => {
    const status = MessageSearchStatusV1Schema.parse({
      v: 1,
      enabled: true,
      state: 'indexing',
      indexBytes: 4096,
      coverage: { messageCount: 120, sessionCount: 3, knownSessionCount: 8, pendingSessionCount: 2, backfillComplete: false },
    });
    expect(messageSearchProgress(status.coverage)).toBe(0.75);
    expect(messageSearchProgress({ ...status.coverage!, knownSessionCount: 0, pendingSessionCount: 0 })).toBe(0);
    expect(MessageSearchStatusV1Schema.parse({ v: 1, enabled: false, state: 'off', indexBytes: null, coverage: null }).state).toBe('off');
  });
});

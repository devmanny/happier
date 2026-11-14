import { describe, expect, it } from 'vitest';

import * as protocol from '../index.js';

type ProviderAccountUsageRecordKeyV1 = Readonly<{
  providerId: string;
  accountSubjectId: string;
  subjectKind: string;
  quotaScope: string;
}>;

function requireFunction(name: string): (...args: readonly unknown[]) => unknown {
  const value = (protocol as Record<string, unknown>)[name];
  expect(typeof value).toBe('function');
  return value as (...args: readonly unknown[]) => unknown;
}

function key(accountSubjectId: string): ProviderAccountUsageRecordKeyV1 {
  return {
    providerId: 'codex',
    accountSubjectId,
    subjectKind: 'account',
    quotaScope: 'account',
  };
}

describe('provider account usage refs session metadata', () => {
  it('writes sanitized canonical record ids into session metadata', () => {
    const buildRecordId = requireFunction('buildProviderAccountUsageRecordId');
    const readRefs = requireFunction('readProviderAccountUsageRecordIdsFromMetadata');
    const writeRef = requireFunction('writeProviderAccountUsageRecordIdToMetadata');
    const firstRecordId = buildRecordId(key('acct_1'));
    const secondRecordId = buildRecordId(key('acct_2'));

    const metadata = writeRef({}, {
      recordId: firstRecordId,
      updatedAtMs: 1_000,
    });
    const nextMetadata = writeRef(metadata, {
      recordId: secondRecordId,
      updatedAtMs: 2_000,
    });

    expect(protocol.SessionMetadataSchema.safeParse(nextMetadata).success).toBe(true);
    expect(readRefs(nextMetadata)).toEqual([firstRecordId, secondRecordId]);
    expect((nextMetadata as Record<string, unknown>).providerAccountUsageRefsV1).toEqual({
      v: 1,
      recordIds: [firstRecordId, secondRecordId],
      updatedAtMs: 2_000,
    });
  });

  it('moves a republished record id to the end so the last ref is the account the session runs on now', () => {
    const buildRecordId = requireFunction('buildProviderAccountUsageRecordId');
    const readRefs = requireFunction('readProviderAccountUsageRecordIdsFromMetadata');
    const writeRef = requireFunction('writeProviderAccountUsageRecordIdToMetadata');
    const firstAccount = buildRecordId(key('acct_first'));
    const secondAccount = buildRecordId(key('acct_second'));

    const switchedBack = [firstAccount, secondAccount, firstAccount].reduce<Record<string, unknown>>(
      (metadata, recordId, index) => writeRef(metadata, { recordId, updatedAtMs: 1_000 + index }) as Record<string, unknown>,
      {},
    );

    expect(readRefs(switchedBack)).toEqual([secondAccount, firstAccount]);
  });

  it('deduplicates existing refs, ignores malformed record ids, and keeps the newest bounded window', () => {
    const buildRecordId = requireFunction('buildProviderAccountUsageRecordId');
    const readRefs = requireFunction('readProviderAccountUsageRecordIdsFromMetadata');
    const writeRef = requireFunction('writeProviderAccountUsageRecordIdToMetadata');
    const recordIds = Array.from({ length: 36 }, (_, index) => buildRecordId(key(`acct_${index}`)));
    const metadata = recordIds.reduce<Record<string, unknown>>((acc, recordId, index) => (
      writeRef(acc, {
        recordId,
        updatedAtMs: 1_000 + index,
      }) as Record<string, unknown>
    ), {
      providerAccountUsageRefsV1: {
        v: 1,
        recordIds: [recordIds[0], 'paug_v1_not-valid?', recordIds[0]],
        updatedAtMs: 500,
      },
    });

    expect(readRefs(metadata)).toEqual(recordIds.slice(-32));
  });
});

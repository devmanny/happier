import { describe, expect, it } from 'vitest';

import {
  SessionRestoreFilesRpcParamsSchema,
  SessionRestoreFilesRpcResultSchema,
} from './sessionRestoreFiles.js';

describe('session.restoreFiles', () => {
  it('accepts a restore before a committed user message, with or without a dry run', () => {
    const params = {
      v: 1,
      sessionId: 'sess_1',
      target: { type: 'before_user_message', userMessageSeq: 7 },
      dryRun: true,
    };
    expect(SessionRestoreFilesRpcParamsSchema.parse(params)).toEqual(params);
    expect(SessionRestoreFilesRpcParamsSchema.parse({ ...params, dryRun: undefined })).toEqual({
      v: 1,
      sessionId: 'sess_1',
      target: { type: 'before_user_message', userMessageSeq: 7 },
    });
  });

  it('rejects unknown params, an uncommitted message and other targets', () => {
    const base = { v: 1, sessionId: 'sess_1', target: { type: 'before_user_message', userMessageSeq: 7 } };
    expect(SessionRestoreFilesRpcParamsSchema.safeParse({ ...base, checkpointId: 'u-1' }).success).toBe(false);
    expect(SessionRestoreFilesRpcParamsSchema.safeParse({
      ...base,
      target: { type: 'before_user_message', userMessageSeq: 0 },
    }).success).toBe(false);
    expect(SessionRestoreFilesRpcParamsSchema.safeParse({
      ...base,
      target: { type: 'before_user_message', userMessageSeq: 7, uuid: 'u-1' },
    }).success).toBe(false);
    expect(SessionRestoreFilesRpcParamsSchema.safeParse({ ...base, target: { type: 'latest_turn' } }).success).toBe(false);
    expect(SessionRestoreFilesRpcParamsSchema.safeParse({ ...base, sessionId: '' }).success).toBe(false);
  });

  it('distinguishes a restorable result, a non-restorable reason and a failure', () => {
    expect(SessionRestoreFilesRpcResultSchema.parse({
      ok: true,
      restorable: true,
      restored: false,
      filesChanged: ['/repo/a.txt'],
      insertions: 1,
      deletions: 2,
    })).toMatchObject({ restorable: true, restored: false });
    expect(SessionRestoreFilesRpcResultSchema.parse({
      ok: true,
      restorable: false,
      reasonCode: 'no_checkpoint',
      reason: 'No file checkpoint found for this message.',
    })).toMatchObject({ restorable: false, reasonCode: 'no_checkpoint' });
    expect(SessionRestoreFilesRpcResultSchema.safeParse({
      ok: true,
      restorable: false,
      reasonCode: 'checkpointing_off',
      reason: 'x',
    }).success).toBe(false);
    expect(SessionRestoreFilesRpcResultSchema.parse({
      ok: false,
      errorCode: 'restore_failed',
      errorMessage: 'Failed to rewind',
    })).toMatchObject({ ok: false, errorCode: 'restore_failed' });
  });
});

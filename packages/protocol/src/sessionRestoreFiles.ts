import { z } from 'zod';

/**
 * Restores the session's working-directory files to the state they were in just
 * before one committed user message, using the Agent's own file checkpoints.
 *
 * Daemon machine RPC (`session.restoreFiles`), like `session.fork`. Restoring
 * changes the session's working directory on disk, which any fork sharing that
 * directory also sees. It never changes the conversation.
 *
 * Callers must not request a real restore while the session's Agent is in the
 * middle of a turn: the daemon does not check for one, and the restore would
 * race the Agent's own edits. A dry run is always safe.
 *
 * The target mirrors `session.rollback`'s `before_user_message` shape, but a
 * restore requires a committed message (`userMessageSeq >= 1`).
 */
export const SessionRestoreFilesTargetSchema = z
  .object({
    type: z.literal('before_user_message'),
    userMessageSeq: z.number().int().min(1),
  })
  .strict();
export type SessionRestoreFilesTarget = z.infer<typeof SessionRestoreFilesTargetSchema>;

export const SessionRestoreFilesRpcParamsSchema = z
  .object({
    v: z.literal(1),
    sessionId: z.string().min(1),
    target: SessionRestoreFilesTargetSchema,
    /** Report what a restore would change without touching any file. */
    dryRun: z.boolean().optional(),
  })
  .strict();
export type SessionRestoreFilesRpcParams = z.infer<typeof SessionRestoreFilesRpcParamsSchema>;

/**
 * `unsupported`: the session's Agent has no file-restore support.
 * `no_checkpoint`: the Agent supports restores, but no checkpoint can be
 * verified for this message (for example a message sent while the Agent was
 * busy, a message from before the conversation was compacted, or checkpoints
 * turned off).
 */
export const SessionRestoreFilesNotRestorableReasonCodeSchema = z.enum(['unsupported', 'no_checkpoint']);
export type SessionRestoreFilesNotRestorableReasonCode = z.infer<typeof SessionRestoreFilesNotRestorableReasonCodeSchema>;

export const SESSION_RESTORE_FILES_ERROR_CODES = {
  /**
   * The Agent could not complete the restore; `errorMessage` carries its reason.
   * A real restore may have changed some files before failing; the message then
   * names the files that still differ from the checkpoint.
   */
  RESTORE_FAILED: 'restore_failed',
} as const;

export const SessionRestoreFilesRpcResultSchema = z.union([
  z
    .object({
      ok: z.literal(true),
      restorable: z.literal(true),
      /** False on a dry run. */
      restored: z.boolean(),
      /** Paths exactly as the Agent reports them. */
      filesChanged: z.array(z.string()),
      insertions: z.number().int().nonnegative().optional(),
      deletions: z.number().int().nonnegative().optional(),
    })
    .strict(),
  z
    .object({
      ok: z.literal(true),
      restorable: z.literal(false),
      reasonCode: SessionRestoreFilesNotRestorableReasonCodeSchema,
      reason: z.string().min(1),
    })
    .strict(),
  z
    .object({
      ok: z.literal(false),
      errorCode: z.string().min(1),
      errorMessage: z.string().min(1),
    })
    .strict(),
]);
export type SessionRestoreFilesRpcResult = z.infer<typeof SessionRestoreFilesRpcResultSchema>;

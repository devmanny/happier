import type { Query, RewindFilesResult } from '@anthropic-ai/claude-agent-sdk';

/**
 * The single reading of Claude's `rewindFiles` control request, shared by the Agent SDK runner's
 * `/rewind` command and the daemon's `session.restoreFiles` owner.
 *
 * Claude Code 2.1.326 (`rewind_files` control handler) answers:
 * - a dry run with `{ canRewind, error?, filesChanged?, insertions?, deletions? }`, where
 *   `canRewind: false` carries why ("File rewinding is not enabled.", "No file checkpoint found
 *   for this message.");
 * - a real run with `{ canRewind: true, skippedLinks }` and no file list as soon as one differing
 *   file was restored, and with an error response only when none was, which the SDK surfaces as a
 *   rejected promise ("... Failed to rewind: ..."). Files it could not restore (missing backup,
 *   write failure, link-safety refusal) are counted at most, never named.
 *
 * The file list therefore only ever comes from a dry run, and a real rewind is complete only when a
 * dry run right after it finds nothing left to restore (`rewindClaudeFilesVerified`).
 */
export type ClaudeRewindFilesOutcome =
  | Readonly<{ status: 'ok'; filesChanged: string[]; insertions?: number; deletions?: number }>
  | Readonly<{ status: 'not_rewindable'; reason: string }>
  | Readonly<{ status: 'failed'; reason: string }>;

type ClaudeRewindFilesQuery = Readonly<{ rewindFiles?: Query['rewindFiles'] }>;

function readNonNegativeInt(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isInteger(value) && value >= 0 ? value : undefined;
}

function readErrorText(value: unknown): string | null {
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : null;
}

function interpretRewindFilesResult(result: RewindFilesResult | undefined): ClaudeRewindFilesOutcome {
  if (!result || typeof result !== 'object' || result.canRewind !== true) {
    return {
      status: 'not_rewindable',
      reason: readErrorText(result?.error) ?? 'Claude cannot restore files to this checkpoint.',
    };
  }
  const insertions = readNonNegativeInt(result.insertions);
  const deletions = readNonNegativeInt(result.deletions);
  return {
    status: 'ok',
    filesChanged: Array.isArray(result.filesChanged)
      ? result.filesChanged.filter((path): path is string => typeof path === 'string')
      : [],
    ...(insertions !== undefined ? { insertions } : {}),
    ...(deletions !== undefined ? { deletions } : {}),
  };
}

/** Settles with `promise`, or rejects with the abort reason as soon as `signal` aborts. */
function settleUnlessAborted<T>(promise: Promise<T>, signal: AbortSignal | undefined): Promise<T> {
  if (!signal) return promise;
  return new Promise<T>((resolve, reject) => {
    const onAbort = () => reject(signal.reason);
    signal.addEventListener('abort', onAbort, { once: true });
    promise.then(resolve, reject).finally(() => signal.removeEventListener('abort', onAbort));
  });
}

/** Cancellation through `signal` rejects with its reason; every Claude-side failure is an outcome. */
export async function requestClaudeRewindFiles(
  query: ClaudeRewindFilesQuery | null | undefined,
  userMessageId: string,
  options: Readonly<{ dryRun: boolean; signal?: AbortSignal }>,
): Promise<ClaudeRewindFilesOutcome> {
  options.signal?.throwIfAborted();
  const rewindFiles = query?.rewindFiles;
  if (typeof rewindFiles !== 'function') {
    return { status: 'failed', reason: 'This Claude Code session cannot rewind files.' };
  }
  let result: RewindFilesResult;
  try {
    result = await settleUnlessAborted(
      rewindFiles.call(query, userMessageId, options.dryRun ? { dryRun: true } : undefined),
      options.signal,
    );
  } catch (error) {
    if (options.signal?.aborted) throw options.signal.reason;
    return {
      status: 'failed',
      reason: readErrorText(error instanceof Error ? error.message : error) ?? 'Claude could not rewind files.',
    };
  }
  return interpretRewindFilesResult(result);
}

export type ClaudeVerifiedRewindOutcome =
  | Readonly<{ status: 'ok' }>
  | Readonly<{ status: 'failed'; reason: string }>;

/**
 * A real rewind, then a dry run in the same Claude session naming whatever still differs from the
 * checkpoint. Anything left over was not restored, even though Claude answered success.
 */
export async function rewindClaudeFilesVerified(
  query: ClaudeRewindFilesQuery | null | undefined,
  userMessageId: string,
  options: Readonly<{ signal?: AbortSignal }> = {},
): Promise<ClaudeVerifiedRewindOutcome> {
  const rewind = await requestClaudeRewindFiles(query, userMessageId, { dryRun: false, signal: options.signal });
  if (rewind.status !== 'ok') return { status: 'failed', reason: rewind.reason };
  const remaining = await requestClaudeRewindFiles(query, userMessageId, { dryRun: true, signal: options.signal });
  if (remaining.status !== 'ok') {
    return { status: 'failed', reason: `Claude rewound files but could not confirm the result: ${remaining.reason}` };
  }
  if (remaining.filesChanged.length > 0) {
    return {
      status: 'failed',
      reason: `Claude restored only some files. These still differ from the checkpoint: ${remaining.filesChanged.join(', ')}`,
    };
  }
  return { status: 'ok' };
}

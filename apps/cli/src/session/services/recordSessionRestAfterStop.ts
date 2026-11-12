import {
  SESSION_REST_METADATA_KEY,
  isSessionStopConfirmed,
  type SessionRestReason,
  type SessionRestV1,
} from '@happier-dev/protocol';

import type { Credentials } from '@/persistence';
import { logger } from '@/ui/logger';

import type { requestSessionStop } from './requestSessionStop';
import { updateSessionMetadataForTarget } from './updateSessionMetadataForTarget';

type SessionStopRequestResult = Awaited<ReturnType<typeof requestSessionStop>>;

export type SessionRestRecording =
  | Readonly<{ sessionRest: SessionRestV1 }>
  | Readonly<{ sessionRestError: string }>;

function readErrorCode(error: unknown): string {
  const code = error && typeof error === 'object' ? (error as { code?: unknown }).code : undefined;
  return typeof code === 'string' && code.trim().length > 0 ? code : 'session_rest_write_failed';
}

/**
 * Records why an automatic stop happened (`sessionRestV1`) once the stop is confirmed, including
 * for a Session that was already stopped. An unconfirmed stop is returned untouched: a rest
 * describes a stop that happened. A failed write leaves the confirmed stop as it is and is
 * reported to the caller as `sessionRestError`.
 */
export async function recordSessionRestAfterStop(params: Readonly<{
  credentials: Credentials;
  stop: SessionStopRequestResult;
  reason: SessionRestReason;
}>): Promise<SessionStopRequestResult | (SessionStopRequestResult & SessionRestRecording)> {
  const { stop } = params;
  if (!stop.ok || !isSessionStopConfirmed(stop)) return stop;

  const sessionRest: SessionRestV1 = { v: 1, reason: params.reason, at: Date.now() };
  try {
    const res = await updateSessionMetadataForTarget({
      credentials: params.credentials,
      idOrPrefix: stop.sessionId,
      updater: (metadata) => ({ ...metadata, [SESSION_REST_METADATA_KEY]: sessionRest }),
    });
    return res.ok ? { ...stop, sessionRest } : { ...stop, sessionRestError: res.code };
  } catch (error) {
    const sessionRestError = readErrorCode(error);
    logger.debug('[SESSION STOP] Could not record the session rest', { sessionId: stop.sessionId, sessionRestError });
    return { ...stop, sessionRestError };
  }
}

import type { AgentState } from '@/api/types';

import { readEffectiveParentSessionId, readListParentLink, type ChildSessionState } from './childSessionNotice';
import { notifyParentLinkChangeBestEffort, type ParentSessionNoticeSession } from './notifyParentSession';

export type ParentLinkWatchedSession = ParentSessionNoticeSession & Readonly<{
  on: (event: 'metadata-updated', listener: () => void) => unknown;
  off: (event: 'metadata-updated', listener: () => void) => unknown;
  getAgentStateSnapshot?: () => AgentState | null | undefined;
  getSessionPresenceSnapshot?: () => Readonly<{ thinking: boolean }>;
}>;

type WatcherState = {
  /** `undefined` until the first metadata snapshot is available; that first value is the baseline. */
  lastSeenParentId: string | null | undefined;
  /** Serialized `listParentV1` last seen; only a change here is a manual move. */
  lastSeenListLink: string | null | undefined;
  detach: () => void;
};

function serializeListLink(metadata: unknown): string | null {
  const link = readListParentLink(metadata);
  return link ? `${link.parentSessionId ?? ''}|${link.updatedAt ?? ''}` : null;
}

/**
 * One watcher per session id. A session client swap (offline → real, reconnect) re-arms
 * the listener on the new client but keeps the last seen parent, so the swap itself
 * never looks like a move.
 */
const watchersBySessionId = new Map<string, WatcherState>();

function readMetadata(session: ParentLinkWatchedSession): unknown {
  try {
    return session.getMetadataSnapshot?.() ?? null;
  } catch {
    return null;
  }
}

function readChildState(session: ParentLinkWatchedSession): ChildSessionState {
  try {
    const requests = session.getAgentStateSnapshot?.()?.requests;
    if (requests && Object.keys(requests).length > 0) return 'blocked';
    if (session.getSessionPresenceSnapshot?.().thinking === true) return 'working';
  } catch {
    // A state read failure must not break the announcement; report the neutral state.
  }
  return 'ready';
}

/**
 * Watch this session's own metadata for a manual move in the app (`listParentV1`) that
 * changes the direct parent, and announce it. The parent seen when the watcher starts is
 * the baseline and is not announced. The spawn link (`spawnedBySessionV1`) is written by
 * the spawner and may land after startup; it is creation, not a move, so it only updates
 * the baseline.
 */
export function startParentLinkWatcher(session: ParentLinkWatchedSession): void {
  const sessionId = session.sessionId;
  if (!sessionId || sessionId.startsWith('offline-')) return;

  const previous = watchersBySessionId.get(sessionId);
  previous?.detach();

  const initialMetadata = readMetadata(session);
  const state: WatcherState = {
    lastSeenParentId: previous
      ? previous.lastSeenParentId
      : initialMetadata
        ? readEffectiveParentSessionId(initialMetadata)
        : undefined,
    lastSeenListLink: previous
      ? previous.lastSeenListLink
      : initialMetadata
        ? serializeListLink(initialMetadata)
        : undefined,
    detach: () => undefined,
  };

  const onMetadataUpdated = () => {
    const metadata = readMetadata(session);
    if (!metadata) return;
    const nextParentId = readEffectiveParentSessionId(metadata);
    const nextListLink = serializeListLink(metadata);
    const listLinkChanged = state.lastSeenListLink !== undefined && nextListLink !== state.lastSeenListLink;
    const previousParentId = state.lastSeenParentId;
    state.lastSeenListLink = nextListLink;
    state.lastSeenParentId = nextParentId;
    if (!listLinkChanged || previousParentId === undefined || nextParentId === previousParentId) return;
    void notifyParentLinkChangeBestEffort({
      session,
      previousParentSessionId: previousParentId,
      nextParentSessionId: nextParentId,
      updatedAt: readListParentLink(metadata)?.updatedAt ?? null,
      childState: readChildState(session),
    }).catch(() => undefined);
  };

  session.on('metadata-updated', onMetadataUpdated);
  state.detach = () => {
    session.off('metadata-updated', onMetadataUpdated);
  };
  watchersBySessionId.set(sessionId, state);
}

export function resetParentLinkWatchersForTests(): void {
  for (const watcher of watchersBySessionId.values()) watcher.detach();
  watchersBySessionId.clear();
}

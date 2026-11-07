import { isSessionNotificationsMuted } from '@happier-dev/protocol';

export type NotificationMuteWatchedSession = Readonly<{
  sessionId: string;
  getMetadataSnapshot?: () => unknown;
}>;

/**
 * The sessions this process runs, so the notification dispatcher can read each one's bell
 * (`metadata.notificationsMutedV1`) at send time. A client swap for the same session replaces
 * the reader. Sessions this process doesn't run are never muted here.
 */
const metadataReaders = new Map<string, () => unknown>();

export function trackSessionNotificationMute(session: NotificationMuteWatchedSession): void {
  if (!session.sessionId || !session.getMetadataSnapshot) return;
  const read = session.getMetadataSnapshot;
  metadataReaders.set(session.sessionId, () => read.call(session));
}

export function isSessionNotificationMuted(sessionId: string | null | undefined): boolean {
  if (!sessionId) return false;
  const read = metadataReaders.get(sessionId);
  if (!read) return false;
  try {
    return isSessionNotificationsMuted(read());
  } catch {
    return false;
  }
}

export function resetSessionNotificationMuteForTests(): void {
  metadataReaders.clear();
}

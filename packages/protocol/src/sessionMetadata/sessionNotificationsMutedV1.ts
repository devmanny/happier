/**
 * The session's notification bell. Notifications are on by default; a client turns them off by
 * writing `{ v: 1, muted: true, updatedAt }`. A muted session never notifies the user's devices
 * or channels, but still talks to its parent session (which notifies as usual).
 */
export const SESSION_NOTIFICATIONS_MUTED_METADATA_KEY = 'notificationsMutedV1';

export function isSessionNotificationsMuted(metadata: unknown): boolean {
  if (metadata === null || typeof metadata !== 'object') return false;
  const entry = (metadata as Record<string, unknown>)[SESSION_NOTIFICATIONS_MUTED_METADATA_KEY];
  return entry !== null && typeof entry === 'object' && (entry as Record<string, unknown>).muted === true;
}

import { AGENT_IDENTITY_METADATA_KEY, AGENT_PRESENCE_HEARTBEAT_MS } from '@happier-dev/protocol';

import { resolveAccountScopedCryptoMaterial, type Credentials } from '@/persistence';
import { logger } from '@/ui/logger';

import { createPresenceKvHttpTransport } from './presenceKvHttpTransport';
import { SessionPresence, type PresenceKvTransport, type PresenceSelfDescription } from './sessionPresence';

export type PresenceWatchedSession = Readonly<{
  sessionId: string;
  on: (event: 'local-presence', listener: (presence: Readonly<{ thinking: boolean }>) => void) => unknown;
  off: (event: 'local-presence', listener: (presence: Readonly<{ thinking: boolean }>) => void) => unknown;
  getMetadataSnapshot?: () => unknown;
}>;

type Entry = { presence: SessionPresence; detach: () => void };

/** One presence per session id; a client swap (offline → real, reconnect) keeps the same one. */
const presenceBySessionId = new Map<string, Entry>();

function readString(record: Record<string, unknown> | null, key: string): string | null {
  const value = record?.[key];
  return typeof value === 'string' && value.trim().length > 0 ? value : null;
}

function readRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

export function describeSessionForPresence(metadata: unknown): PresenceSelfDescription {
  const record = readRecord(metadata);
  const identity = readRecord(record?.[AGENT_IDENTITY_METADATA_KEY]);
  const identityId = readString(identity, 'id');
  const identityName = readString(identity, 'name');
  const emoji = readString(identity, 'emoji');
  return {
    agent: identityId && identityName ? { id: identityId, name: identityName, ...(emoji ? { emoji } : {}) } : null,
    providerId: readString(record, 'flavor'),
    machineId: readString(record, 'machineId'),
    host: readString(record, 'host'),
    directory: readString(record, 'path'),
    task: readString(readRecord(record?.summary), 'text') ?? readString(record, 'name'),
  };
}

/** Presence is advisory: a failure never stops the session, but it is always logged. */
export function reportPresenceFailure(action: string) {
  return (error: unknown) => {
    logger.warn(`[presence] ${action} failed (non-fatal)`, { error: error instanceof Error ? error.message : String(error) });
  };
}

/**
 * Publish this runner's "who is where" record while its turns run (`local-presence` thinking),
 * with a heartbeat so a crashed runner ages out. Accounts without key material are skipped.
 */
export function startSessionPresence(
  session: PresenceWatchedSession,
  credentials: Credentials,
  deps: Readonly<{ transport?: PresenceKvTransport }> = {},
): SessionPresence | null {
  const sessionId = session.sessionId;
  if (!sessionId || sessionId.startsWith('offline-') || !credentials.encryption) return null;

  const previous = presenceBySessionId.get(sessionId);
  previous?.detach();
  const presence = previous?.presence ?? new SessionPresence({
    sessionId,
    transport: deps.transport ?? createPresenceKvHttpTransport({ token: credentials.token }),
    material: resolveAccountScopedCryptoMaterial(credentials),
    describeSelf: () => describeSessionForPresence(session.getMetadataSnapshot?.() ?? null),
  });

  const onLocalPresence = (snapshot: Readonly<{ thinking: boolean }>) => {
    void presence.setWorking(snapshot.thinking === true).catch(reportPresenceFailure('publish'));
  };
  session.on('local-presence', onLocalPresence);
  const heartbeat = setInterval(() => {
    void presence.heartbeat().catch(reportPresenceFailure('heartbeat'));
  }, AGENT_PRESENCE_HEARTBEAT_MS);
  heartbeat.unref?.();

  presenceBySessionId.set(sessionId, {
    presence,
    detach: () => {
      session.off('local-presence', onLocalPresence);
      clearInterval(heartbeat);
    },
  });
  return presence;
}

export function getSessionPresence(sessionId: string | null | undefined): SessionPresence | null {
  return sessionId ? presenceBySessionId.get(sessionId)?.presence ?? null : null;
}

export function resetSessionPresenceForTests(): void {
  for (const entry of presenceBySessionId.values()) entry.detach();
  presenceBySessionId.clear();
}

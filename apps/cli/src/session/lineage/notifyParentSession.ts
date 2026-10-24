import { getSessionNotificationTitle } from '@/agent/runtime/readyNotificationContext';
import { readCredentials, type Credentials } from '@/persistence';
import { sendSessionMessage, type SendSessionMessageResult } from '@/session/services/sendSessionMessage';
import { tryDecryptSessionMetadata } from '@/session/transport/encryption/sessionEncryptionContext';
import { fetchSessionById } from '@/session/transport/http/sessionsHttp';
import { logger } from '@/ui/logger';

import {
  buildChildAdoptedNoticeMessage,
  buildChildReleasedNoticeMessage,
  buildChildSessionNoticeMessage,
  buildReparentedSelfNoticeMessage,
  readEffectiveParentSessionId,
  readSessionNoticeLocation,
  type ChildSessionNoticeEvent,
  type ChildSessionState,
} from './childSessionNotice';

export type ParentSessionNoticeSession = Readonly<{
  sessionId: string;
  getMetadataSnapshot?: (() => unknown) | null;
}>;

export type ParentSessionNoticeDeps = Readonly<{
  readCredentials: () => Promise<Credentials | null>;
  sendSessionMessage: (params: Parameters<typeof sendSessionMessage>[0]) => Promise<SendSessionMessageResult>;
  /** Decrypted metadata of another session, or null when it does not exist. */
  readSessionMetadata: (sessionId: string, credentials: Credentials) => Promise<unknown>;
  log: (message: string, details: unknown) => void;
}>;

const LOG_PREFIX = '[parentSessionNotice]';

/**
 * The runner never waits on the parent. `timeoutMs` only bounds the optional
 * latency nudge inside `sendSessionMessage` (already capped there); the durable
 * wake is the parent's Pending row. Same default the `session send` command uses.
 */
const NOTICE_SEND_TIMEOUT_MS = 300_000;

type ChildNoticeState = {
  lastTurnKey: string | null;
  sentKeys: Set<string>;
  stopped: boolean;
};

/**
 * One session runs per process, but the state is keyed by child session id so a
 * placeholder → real session swap during startup cannot leak dedupe state.
 */
const stateByChildSessionId = new Map<string, ChildNoticeState>();

const defaultDeps: ParentSessionNoticeDeps = {
  readCredentials,
  sendSessionMessage,
  readSessionMetadata: async (sessionId, credentials) => {
    const rawSession = await fetchSessionById({ token: credentials.token, sessionId });
    return rawSession ? tryDecryptSessionMetadata({ credentials, rawSession }) : null;
  },
  log: (message, details) => logger.debug(message, details),
};

let cachedCredentials: Promise<Credentials | null> | null = null;

function readCachedCredentials(deps: ParentSessionNoticeDeps): Promise<Credentials | null> {
  if (deps !== defaultDeps) return deps.readCredentials();
  cachedCredentials ??= deps.readCredentials().catch(() => null);
  return cachedCredentials;
}

function stateFor(childSessionId: string): ChildNoticeState {
  let state = stateByChildSessionId.get(childSessionId);
  if (!state) {
    state = { lastTurnKey: null, sentKeys: new Set(), stopped: false };
    stateByChildSessionId.set(childSessionId, state);
  }
  return state;
}

function turnKeyFor(event: Extract<ChildSessionNoticeEvent, { kind: 'turn_completed' }>): string {
  const explicit = typeof event.turnKey === 'string' ? event.turnKey.trim() : '';
  return explicit.length > 0 ? `turn:${explicit}` : `preview:${event.assistantPreviewText ?? ''}`;
}

/**
 * Decides once per event whether this notice is new. Returns false for a duplicate
 * (retry, reconnect republish, re-emitted ready for the same turn, anything after stop).
 */
function admitEvent(state: ChildNoticeState, event: ChildSessionNoticeEvent): boolean {
  if (state.stopped) return false;
  if (event.kind === 'stopped') {
    state.stopped = true;
    return true;
  }
  if (event.kind === 'turn_completed') {
    const key = turnKeyFor(event);
    if (state.lastTurnKey === key) return false;
    state.lastTurnKey = key;
    return true;
  }
  const key = event.kind === 'blocked'
    ? `blocked:${event.requestId}`
    : `turn_failed:${event.turnKey ?? event.message ?? ''}`;
  if (state.sentKeys.has(key)) return false;
  state.sentKeys.add(key);
  return true;
}

function readMetadataSnapshot(session: ParentSessionNoticeSession): unknown {
  try {
    return session.getMetadataSnapshot?.() ?? null;
  } catch {
    return null;
  }
}

/**
 * Deliver one automatic notice from this session to a target session. Never throws:
 * a missing, archived or unreachable target is logged to the session log file only.
 */
async function deliverNoticeBestEffort(
  params: Readonly<{
    fromSessionId: string;
    targetSessionId: string;
    message: string;
    eventLabel: string;
  }>,
  deps: ParentSessionNoticeDeps,
): Promise<void> {
  const context = { fromSessionId: params.fromSessionId, targetSessionId: params.targetSessionId, event: params.eventLabel };
  try {
    const credentials = await readCachedCredentials(deps);
    if (!credentials) {
      deps.log(`${LOG_PREFIX} No credentials available; skipping notice`, context);
      return;
    }
    const result = await deps.sendSessionMessage({
      credentials,
      idOrPrefix: params.targetSessionId,
      message: params.message,
      wait: false,
      timeoutMs: NOTICE_SEND_TIMEOUT_MS,
      // Wake an idle target; never restart one the user stopped. The notice stays
      // queued and is delivered when the target resumes.
      resumeInactiveSession: false,
    });
    if (!result.ok) {
      deps.log(`${LOG_PREFIX} Target did not accept notice (${result.code})`, {
        ...context,
        ...(result.message ? { message: result.message } : {}),
      });
    }
  } catch (error) {
    deps.log(`${LOG_PREFIX} Failed to deliver notice`, {
      ...context,
      error: error instanceof Error ? error.message : String(error),
    });
  }
}

/**
 * The app can nest a session under one of its own children. Each would then report every
 * finished turn to the other and wake it, forever. The child side breaks the cycle: a
 * parent whose own effective parent is this session is not reported to. An unreadable
 * parent is not evidence of a cycle, so the notice still goes out.
 */
async function isMutualNesting(
  params: Readonly<{ childSessionId: string; parentSessionId: string }>,
  deps: ParentSessionNoticeDeps,
): Promise<boolean> {
  try {
    const credentials = await readCachedCredentials(deps);
    if (!credentials) return false;
    const parentMetadata = await deps.readSessionMetadata(params.parentSessionId, credentials);
    return readEffectiveParentSessionId(parentMetadata) === params.childSessionId;
  } catch {
    return false;
  }
}

/**
 * Report a lifecycle event to this session's direct parent, read from metadata at the
 * moment of the event (manual moves in the app change it live). Never blocks the child.
 */
export async function notifyParentSessionBestEffort(
  params: Readonly<{
    session: ParentSessionNoticeSession;
    event: ChildSessionNoticeEvent;
  }>,
  deps: ParentSessionNoticeDeps = defaultDeps,
): Promise<void> {
  const metadata = readMetadataSnapshot(params.session);
  const parentSessionId = readEffectiveParentSessionId(metadata);
  const childSessionId = params.session.sessionId;
  if (!parentSessionId || parentSessionId === childSessionId) return;

  if (!admitEvent(stateFor(childSessionId), params.event)) return;

  if (await isMutualNesting({ childSessionId, parentSessionId }, deps)) {
    deps.log(`${LOG_PREFIX} Skipping notice: mutual nesting (the parent reports to this session)`, {
      childSessionId,
      parentSessionId,
      event: params.event.kind,
    });
    return;
  }

  await deliverNoticeBestEffort({
    fromSessionId: childSessionId,
    targetSessionId: parentSessionId,
    eventLabel: params.event.kind,
    message: buildChildSessionNoticeMessage({
      childSessionId,
      childSessionTitle: getSessionNotificationTitle(() => metadata),
      event: params.event,
    }),
  }, deps);
}

/**
 * Announce a change of direct parent to the new parent, the previous parent and the
 * child itself. One announcement per transition: retries and reconnect replays of the
 * same `listParentV1.updatedAt` are ignored. Independent of the lifecycle dedupe, so a
 * move after a stop notice (a resumed session) is still announced.
 */
export async function notifyParentLinkChangeBestEffort(
  params: Readonly<{
    session: ParentSessionNoticeSession;
    previousParentSessionId: string | null;
    nextParentSessionId: string | null;
    updatedAt: number | null;
    childState: ChildSessionState;
  }>,
  deps: ParentSessionNoticeDeps = defaultDeps,
): Promise<void> {
  const childSessionId = params.session.sessionId;
  const state = stateFor(childSessionId);
  const transitionKey = `parent_changed:${params.previousParentSessionId ?? ''}->${params.nextParentSessionId ?? ''}:${params.updatedAt ?? ''}`;
  if (state.sentKeys.has(transitionKey)) return;
  state.sentKeys.add(transitionKey);

  const metadata = readMetadataSnapshot(params.session);
  const childSessionTitle = getSessionNotificationTitle(() => metadata);
  const location = readSessionNoticeLocation(metadata);
  const deliveries: Promise<void>[] = [];

  const nextParent = params.nextParentSessionId && params.nextParentSessionId !== childSessionId
    ? params.nextParentSessionId
    : null;
  if (nextParent) {
    deliveries.push(deliverNoticeBestEffort({
      fromSessionId: childSessionId,
      targetSessionId: nextParent,
      eventLabel: 'child_adopted',
      message: buildChildAdoptedNoticeMessage({
        childSessionId,
        childSessionTitle,
        path: location.path,
        host: location.host,
        state: params.childState,
      }),
    }, deps));
  }
  const previousParent = params.previousParentSessionId && params.previousParentSessionId !== childSessionId
    ? params.previousParentSessionId
    : null;
  if (previousParent) {
    deliveries.push(deliverNoticeBestEffort({
      fromSessionId: childSessionId,
      targetSessionId: previousParent,
      eventLabel: 'child_released',
      message: buildChildReleasedNoticeMessage({ childSessionId, childSessionTitle }),
    }, deps));
  }
  deliveries.push(deliverNoticeBestEffort({
    fromSessionId: childSessionId,
    targetSessionId: childSessionId,
    eventLabel: 'reparented',
    message: buildReparentedSelfNoticeMessage({ parentSessionId: nextParent }),
  }, deps));

  await Promise.all(deliveries);
}

/** Fire-and-forget wrapper for synchronous call sites. */
export function notifyParentSessionInBackground(params: Readonly<{
  session: ParentSessionNoticeSession;
  event: ChildSessionNoticeEvent;
}>): void {
  void notifyParentSessionBestEffort(params).catch(() => undefined);
}

export function resetParentSessionNoticeStateForTests(): void {
  stateByChildSessionId.clear();
  cachedCredentials = null;
}

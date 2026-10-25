/**
 * Child → parent session notices.
 *
 * A session created through `session.spawn_new` from another session records
 * `metadata.spawnedBySessionV1` (see `createSpawnedSession`). Moving a session by
 * hand in the app ("Move into…" / "Move to top level") records `metadata.listParentV1`,
 * which takes precedence when present (`parentSessionId: null` means top level).
 * This module owns the effective-parent reader and the text of the automatic notices
 * exchanged between a child and its direct parent.
 */

import type { AgentRequestKind } from '@/agent/permissions/requestKind';

export type ChildSessionState = 'working' | 'ready' | 'blocked';

export type ChildSessionNoticeEvent =
  | Readonly<{
    kind: 'turn_completed';
    assistantPreviewText?: string | null;
    /**
     * Identity of the completed turn when the provider exposes one. Used only to
     * collapse re-emitted ready events for the same turn; absent, the excerpt text
     * stands in for it.
     */
    turnKey?: string | null;
  }>
  | Readonly<{ kind: 'turn_failed'; message: string | null; turnKey?: string | null }>
  | Readonly<{
    kind: 'blocked';
    requestKind: AgentRequestKind;
    requestId: string;
    toolName: string;
    toolDetails: string | null;
  }>
  | Readonly<{ kind: 'stopped'; reason: string; crashed: boolean }>;

export const CHILD_SESSION_NOTICE_HEADER = '[Happier automatic notice — child session event, not a user message]';
export const PARENT_LINK_NOTICE_HEADER = '[Happier automatic notice — session nesting changed, not a user message]';
/** Every notice ends with this so agents keep the conversation to direct kin only. */
export const DIRECT_KIN_GUIDANCE =
  'Communicate only with your direct parent and your direct children; never relay to, or contact, grandparents or grandchildren.';

function readNonBlankString(value: unknown): string | null {
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : null;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

/** Parent session id recorded by `session.spawn_new`, or null when this session was not spawned by one. */
function readSpawnedBySessionParentId(metadata: Record<string, unknown>): string | null {
  const link = asRecord(metadata.spawnedBySessionV1);
  if (!link || link.v !== 1) return null;
  return readNonBlankString(link.parentSessionId);
}

export type ListParentLink = Readonly<{ parentSessionId: string | null; updatedAt: number | null }>;

/** The manual nesting written by the app, or null when the session was never moved by hand. */
export function readListParentLink(metadata: unknown): ListParentLink | null {
  const record = asRecord(metadata);
  const link = record ? asRecord(record.listParentV1) : null;
  if (!link || link.v !== 1) return null;
  const updatedAt = typeof link.updatedAt === 'number' && Number.isFinite(link.updatedAt) ? link.updatedAt : null;
  return { parentSessionId: readNonBlankString(link.parentSessionId), updatedAt };
}

/**
 * The direct parent this session reports to right now. A manual move (`listParentV1`)
 * wins over the spawning session; a manual move to the top level yields null.
 */
export function readEffectiveParentSessionId(metadata: unknown): string | null {
  const record = asRecord(metadata);
  if (!record) return null;
  const manual = readListParentLink(record);
  if (manual) return manual.parentSessionId;
  return readSpawnedBySessionParentId(record);
}

export function readSessionNoticeLocation(metadata: unknown): Readonly<{ path: string | null; host: string | null }> {
  const record = asRecord(metadata);
  return {
    path: readNonBlankString(record?.path),
    host: readNonBlankString(record?.host),
  };
}

function describeEvent(event: ChildSessionNoticeEvent): string {
  switch (event.kind) {
    case 'turn_completed':
      return 'finished its turn and is now idle, waiting for input';
    case 'turn_failed':
      return event.message ? `stopped with an error: ${event.message}` : 'stopped with an error';
    case 'blocked':
      return event.requestKind === 'user_action'
        ? `blocked — waiting for an answer to a question (tool: ${event.toolName})`
        : `blocked — waiting for permission approval (tool: ${event.toolName})`;
    case 'stopped':
      return event.crashed ? `stopped with an error (${event.reason})` : `stopped (${event.reason})`;
  }
}

function describeExcerpt(event: ChildSessionNoticeEvent): readonly string[] {
  if (event.kind === 'turn_completed') {
    const text = readNonBlankString(event.assistantPreviewText);
    return text ? ['Last assistant message (excerpt):', text] : [];
  }
  if (event.kind === 'blocked') {
    const details = readNonBlankString(event.toolDetails);
    return details ? ['Pending request:', details] : [];
  }
  return [];
}

function describeHowToReply(childSessionId: string, event: ChildSessionNoticeEvent): string {
  const sendCommand = `happier session send ${childSessionId} "<your message>"`;
  if (event.kind === 'blocked') {
    return `Approve or answer it from the Happier app, or send guidance with: ${sendCommand}`;
  }
  if (event.kind === 'stopped') {
    return `Sending it a message resumes it: ${sendCommand}`;
  }
  return `To reply to it, run: ${sendCommand}`;
}

export function buildChildSessionNoticeMessage(params: Readonly<{
  childSessionId: string;
  childSessionTitle: string | null;
  event: ChildSessionNoticeEvent;
}>): string {
  const title = readNonBlankString(params.childSessionTitle);
  const identity = title
    ? `Child session: "${title}" (id: ${params.childSessionId})`
    : `Child session: ${params.childSessionId}`;
  return [
    CHILD_SESSION_NOTICE_HEADER,
    identity,
    `Event: ${describeEvent(params.event)}`,
    ...describeExcerpt(params.event),
    describeHowToReply(params.childSessionId, params.event),
    DIRECT_KIN_GUIDANCE,
  ].join('\n');
}

function describeChildState(state: ChildSessionState): string {
  if (state === 'blocked') return 'blocked, waiting for a permission approval or an answer';
  if (state === 'working') return 'working on a turn';
  return 'ready, idle and waiting for input';
}

function describeChild(childSessionId: string, childSessionTitle: string | null): string {
  const title = readNonBlankString(childSessionTitle);
  return title ? `"${title}" (id: ${childSessionId})` : childSessionId;
}

/** Notice for the session that just became this child's direct parent. */
export function buildChildAdoptedNoticeMessage(params: Readonly<{
  childSessionId: string;
  childSessionTitle: string | null;
  path: string | null;
  host: string | null;
  state: ChildSessionState;
}>): string {
  return [
    PARENT_LINK_NOTICE_HEADER,
    `You have a new direct child session: ${describeChild(params.childSessionId, params.childSessionTitle)}`,
    ...(params.path ? [`Folder: ${params.path}`] : []),
    ...(params.host ? [`Machine: ${params.host}`] : []),
    `Current state: ${describeChildState(params.state)}`,
    `It will report to you when it finishes a turn, blocks, fails or stops. To talk to it, run: happier session send ${params.childSessionId} "<your message>"`,
    DIRECT_KIN_GUIDANCE,
  ].join('\n');
}

/** Notice for the session that stopped being this child's direct parent. */
export function buildChildReleasedNoticeMessage(params: Readonly<{
  childSessionId: string;
  childSessionTitle: string | null;
}>): string {
  return [
    PARENT_LINK_NOTICE_HEADER,
    `${describeChild(params.childSessionId, params.childSessionTitle)} is no longer your direct child session; it will not report to you anymore.`,
    DIRECT_KIN_GUIDANCE,
  ].join('\n');
}

/** Notice for the child itself, so its agent knows who its direct parent is now. */
export function buildReparentedSelfNoticeMessage(params: Readonly<{
  parentSessionId: string | null;
}>): string {
  const line = params.parentSessionId
    ? `You are now a direct child of session ${params.parentSessionId}. Your turn-complete, blocked, failed and stopped events are reported to it automatically; to talk to it yourself, run: happier session send ${params.parentSessionId} "<your message>"`
    : 'You no longer have a parent session; you are at the top level and your events are not reported to any session.';
  return [PARENT_LINK_NOTICE_HEADER, line, DIRECT_KIN_GUIDANCE].join('\n');
}

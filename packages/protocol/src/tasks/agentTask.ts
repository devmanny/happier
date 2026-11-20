import { z } from 'zod';

import { parseSessionPermissionModeAlias, SESSION_PERMISSION_INTENT_INPUTS, type SessionPermissionMode } from '../sessionMetadata/sessionPermissionModes.js';
import { TaskOccurrenceSchema, TaskRecurrenceV1Schema, TaskScheduledStartV1Schema } from './agentTaskRecurrence.js';

/**
 * A task for the user or one of their agents, sealed in the account's UserKVStore under the opaque
 * key `task/<uuid>` (kind `agent_task`). Titles and everything readable live in the sealed value.
 * Repetition rides on Automations (`agentTaskRecurrence.ts`).
 *
 * Every task schema is passthrough: a field this build doesn't know (written by a newer one) is kept
 * when the task is read and rewritten, so older writers never drop it.
 */
export const AGENT_TASK_KV_PREFIX = 'task/';

export function agentTaskKvKey(taskId: string): string {
  return `${AGENT_TASK_KV_PREFIX}${taskId}`;
}

export const AGENT_TASK_STATUSES = ['todo', 'in_progress', 'blocked', 'in_review', 'done'] as const;
export type AgentTaskStatus = (typeof AGENT_TASK_STATUSES)[number];

const STATUS_LABELS: Record<AgentTaskStatus, string> = {
  todo: 'To do',
  in_progress: 'In progress',
  blocked: 'Blocked',
  in_review: 'In review',
  done: 'Done',
};

/** Who a task is for, or who did something to it. */
const AssigneeSchema = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('user') }).passthrough(),
  z.object({ kind: z.literal('agent'), agentId: z.string().min(1), name: z.string().optional(), emoji: z.string().optional() }).passthrough(),
  /** An existing session, with or without an agent: it is told about the task and works it. */
  z.object({ kind: z.literal('session'), sessionId: z.string().min(1), title: z.string().optional() }).passthrough(),
]);
export type AgentTaskAssignee = z.infer<typeof AssigneeSchema>;

const ActorSchema = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('user') }).passthrough(),
  z.object({ kind: z.literal('agent'), agentId: z.string().min(1), sessionId: z.string().optional() }).passthrough(),
  z.object({ kind: z.literal('session'), sessionId: z.string().min(1) }).passthrough(),
]);
export type AgentTaskActor = z.infer<typeof ActorSchema>;

/** Where the task came from: a chat, an email or a session, with a link back to it. */
const SourceSchema = z.object({
  kind: z.enum(['chat', 'email', 'session', 'other']),
  label: z.string().optional(),
  url: z.string().optional(),
  sessionId: z.string().optional(),
}).passthrough();
export type AgentTaskSource = z.infer<typeof SourceSchema>;

export const AgentTaskV1Schema = z.object({
  v: z.literal(1),
  id: z.string().min(1),
  title: z.string().trim().min(1),
  description: z.string().optional(),
  assignee: AssigneeSchema,
  status: z.enum(AGENT_TASK_STATUSES),
  startAt: z.number().optional(),
  dueAt: z.number().optional(),
  machineId: z.string().optional(),
  directory: z.string().optional(),
  source: SourceSchema.optional(),
  /** Sessions that worked on it, on any machine. */
  threads: z.array(z.string()),
  /** Progress comments and status changes, oldest first. */
  log: z.array(z.object({
    at: z.number(),
    by: ActorSchema,
    text: z.string().optional(),
    status: z.enum(AGENT_TASK_STATUSES).optional(),
  }).passthrough()),
  createdBy: ActorSchema.optional(),
  createdAt: z.number(),
  updatedAt: z.number(),
  /** Repeats on these rules (one Automation per rule). */
  recurrence: TaskRecurrenceV1Schema.optional(),
  /** A one-time start the user scheduled for the assigned agent. */
  scheduledStartV1: TaskScheduledStartV1Schema.optional(),
  /** Each firing of a rule: result and thread, oldest first. */
  occurrences: z.array(TaskOccurrenceSchema).optional(),
  /** When the user was already told it was due soon / overdue, so every machine tells once. */
  notifiedV1: z.object({ dueSoonAt: z.number().optional(), overdueAt: z.number().optional() }).passthrough().optional(),
  /**
   * How every start of this task runs ("Start now", "Schedule…", each occurrence), for an agent or a
   * session. Absent means YOLO, the default for new tasks and for tasks written before the field.
   */
  permissionMode: z.enum(SESSION_PERMISSION_INTENT_INPUTS).optional(),
  /** Set when the user archived it (not going to do it): hidden by default, never deleted. */
  archivedAt: z.number().optional(),
}).passthrough();
export type AgentTaskV1 = z.infer<typeof AgentTaskV1Schema>;

export function parseAgentTaskV1(value: unknown): AgentTaskV1 | null {
  const parsed = AgentTaskV1Schema.safeParse(value);
  return parsed.success ? parsed.data : null;
}

export function isAgentTaskOpen(task: AgentTaskV1): boolean {
  return task.status !== 'done' && task.archivedAt === undefined;
}

export type AgentTaskPermissionIntent = (typeof SESSION_PERMISSION_INTENT_INPUTS)[number];

export function taskPermissionIntent(task: AgentTaskV1): AgentTaskPermissionIntent {
  return task.permissionMode ?? 'yolo';
}

/** The task's permission mode as sessions carry it (spawn option, or a message's intent). */
export function taskSessionPermissionMode(task: AgentTaskV1): SessionPermissionMode {
  return parseSessionPermissionModeAlias(taskPermissionIntent(task)) ?? 'yolo';
}

export type AgentTaskUpdate = Readonly<{
  title?: string;
  description?: string | null;
  assignee?: AgentTaskAssignee;
  status?: AgentTaskStatus;
  startAt?: number | null;
  dueAt?: number | null;
  machineId?: string | null;
  directory?: string | null;
  source?: AgentTaskSource | null;
  comment?: string;
  by?: AgentTaskActor;
  /** The session doing the update, linked to the task once. */
  threadSessionId?: string;
  permissionMode?: AgentTaskPermissionIntent;
  /** Archives (true) or restores (false) the task. */
  archived?: boolean;
}>;

/** The task after `update`; `null` clears an optional field. A status change or comment is logged. */
export function applyAgentTaskUpdate(task: AgentTaskV1, update: AgentTaskUpdate, now: number): AgentTaskV1 {
  const next: Record<string, unknown> = { ...task, updatedAt: now };
  for (const field of ['description', 'startAt', 'dueAt', 'machineId', 'directory', 'source'] as const) {
    const value = update[field];
    if (value === null) delete next[field];
    else if (value !== undefined) next[field] = value;
  }
  if (update.title?.trim()) next.title = update.title.trim();
  if (update.assignee) next.assignee = update.assignee;
  if (update.permissionMode) next.permissionMode = update.permissionMode;
  if (update.archived === true && task.archivedAt === undefined) next.archivedAt = now;
  if (update.archived === false) delete next.archivedAt;
  const statusChanged = update.status !== undefined && update.status !== task.status;
  if (update.status) next.status = update.status;
  if (update.threadSessionId && !task.threads.includes(update.threadSessionId)) {
    next.threads = [...task.threads, update.threadSessionId];
  }
  const comment = update.comment?.trim();
  if (comment || statusChanged) {
    next.log = [...task.log, {
      at: now,
      by: update.by ?? { kind: 'user' },
      ...(comment ? { text: comment } : {}),
      ...(statusChanged ? { status: update.status } : {}),
    }];
  }
  return next as AgentTaskV1;
}

function describeSpan(ms: number): string {
  const hours = Math.round(Math.abs(ms) / 3_600_000);
  if (hours < 1) return `${Math.max(1, Math.round(Math.abs(ms) / 60_000))} min`;
  return hours < 48 ? `${hours} h` : `${Math.round(hours / 24)} days`;
}

export function describeTaskDue(task: AgentTaskV1, now: number): string | null {
  if (task.dueAt === undefined) return null;
  return task.dueAt < now ? `overdue by ${describeSpan(now - task.dueAt)}` : `due in ${describeSpan(task.dueAt - now)}`;
}

export function agentTaskStatusLabel(status: AgentTaskStatus): string {
  return STATUS_LABELS[status];
}

/**
 * A thread's open tasks in a few lines, overdue and soonest first: its board at each turn start.
 * A thread works the tasks assigned to its agent and those assigned to the session itself.
 */
export function buildAgentTaskBoard(params: Readonly<{ agentId?: string | null; sessionId?: string | null; tasks: readonly AgentTaskV1[]; now: number }>): string {
  const isMine = (task: AgentTaskV1) =>
    (task.assignee.kind === 'agent' && !!params.agentId && task.assignee.agentId === params.agentId)
    || (task.assignee.kind === 'session' && !!params.sessionId && task.assignee.sessionId === params.sessionId);
  return params.tasks
    .filter((task) => isMine(task) && isAgentTaskOpen(task))
    .sort((a, b) => (a.dueAt ?? Number.POSITIVE_INFINITY) - (b.dueAt ?? Number.POSITIVE_INFINITY) || a.createdAt - b.createdAt)
    .map((task) => [task.id, task.title, STATUS_LABELS[task.status], describeTaskDue(task, params.now), task.directory]
      .filter(Boolean).join(' · '))
    .map((line) => `- ${line}`)
    .join('\n');
}

/** "Due soon" is the day before the due date. */
export const AGENT_TASK_DUE_SOON_WINDOW_MS = 24 * 3_600_000;

export type AgentTaskDueNotice = Readonly<{ taskId: string; kind: 'due_soon' | 'overdue' }>;

/** The user's open tasks to tell about now: due within a day, or overdue, each only once. */
export function taskDueNotices(params: Readonly<{ tasks: readonly AgentTaskV1[]; now: number }>): AgentTaskDueNotice[] {
  const notices: AgentTaskDueNotice[] = [];
  for (const task of params.tasks) {
    if (task.assignee.kind !== 'user' || !isAgentTaskOpen(task) || task.dueAt === undefined) continue;
    if (task.dueAt <= params.now) {
      if (task.notifiedV1?.overdueAt === undefined) notices.push({ taskId: task.id, kind: 'overdue' });
    } else if (task.dueAt - params.now <= AGENT_TASK_DUE_SOON_WINDOW_MS && task.notifiedV1?.dueSoonAt === undefined) {
      notices.push({ taskId: task.id, kind: 'due_soon' });
    }
  }
  return notices;
}

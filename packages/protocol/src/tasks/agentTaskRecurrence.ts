import { z } from 'zod';

import type { AgentTaskV1 } from './agentTask.js';

/**
 * A task that repeats. Each rule becomes one Automation on the server (cron + time zone, assigned to
 * the task's machine), so the existing Automations engine is the only scheduler: it waits while the
 * machine sleeps and the daemon that claims a run works the occurrence. "Every N days" fires daily at
 * its time and the occurrence day is decided against its anchor date here, because the engine's
 * interval schedule is measured from the previous run's finish and drifts.
 */
const TimeSchema = z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/);
const DateSchema = z.string().regex(/^\d{4}-\d{2}-\d{2}$/);

export const TaskRecurrenceRuleSchema = z.discriminatedUnion('kind', [
  z.object({
    id: z.string().min(1),
    kind: z.literal('weekly'),
    /** 0 = Sunday … 6 = Saturday, as cron counts them. */
    weekdays: z.array(z.number().int().min(0).max(6)).min(1),
    time: TimeSchema,
    automationId: z.string().optional(),
  }).passthrough(),
  z.object({
    id: z.string().min(1),
    kind: z.literal('every_n_days'),
    everyDays: z.number().int().min(1),
    anchorDate: DateSchema,
    time: TimeSchema,
    automationId: z.string().optional(),
  }).passthrough(),
  z.object({
    id: z.string().min(1),
    kind: z.literal('monthly'),
    dayOfMonth: z.number().int().min(1).max(31),
    time: TimeSchema,
    automationId: z.string().optional(),
  }).passthrough(),
]);
export type TaskRecurrenceRule = z.infer<typeof TaskRecurrenceRuleSchema>;

export const TaskRecurrenceV1Schema = z.object({
  v: z.literal(1),
  /** IANA time zone the rules' times are in (the user's). */
  timezone: z.string().min(1),
  /** Each occurrence continues the task's last thread, or opens a new one. */
  continuity: z.enum(['same_thread', 'new_thread']),
  paused: z.boolean(),
  rules: z.array(TaskRecurrenceRuleSchema).min(1),
}).passthrough();
export type TaskRecurrenceV1 = z.infer<typeof TaskRecurrenceV1Schema>;

export const TASK_OCCURRENCE_STATUSES = ['running', 'completed', 'skipped', 'failed', 'interrupted'] as const;

/** One firing of a rule, in the task's history: what happened and in which thread. */
export const TaskOccurrenceSchema = z.object({
  /** The Automation run id: unique per firing, so recording it twice is harmless. */
  id: z.string().min(1),
  ruleId: z.string().optional(),
  dueAt: z.number().optional(),
  startedAt: z.number(),
  finishedAt: z.number().optional(),
  sessionId: z.string().optional(),
  status: z.enum(TASK_OCCURRENCE_STATUSES),
  note: z.string().optional(),
}).passthrough();
export type TaskOccurrence = z.infer<typeof TaskOccurrenceSchema>;

function parseTime(time: string): { hour: number; minute: number } {
  const [hour, minute] = time.split(':').map((part) => Number.parseInt(part, 10));
  return { hour: hour!, minute: minute! };
}

/** The cron expression of a rule, read by the server in the recurrence's time zone. */
export function recurrenceRuleCron(rule: TaskRecurrenceRule): string {
  const { hour, minute } = parseTime(rule.time);
  if (rule.kind === 'weekly') {
    const days = [...new Set(rule.weekdays)].sort((a, b) => a - b).join(',');
    return `${minute} ${hour} * * ${days}`;
  }
  if (rule.kind === 'monthly') return `${minute} ${hour} ${rule.dayOfMonth} * *`;
  return `${minute} ${hour} * * *`;
}

function localDateInZone(at: number, timezone: string): string {
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit' })
    .formatToParts(new Date(at));
  const part = (type: string) => parts.find((entry) => entry.type === type)?.value ?? '';
  return `${part('year')}-${part('month')}-${part('day')}`;
}

function daysBetween(fromDate: string, toDate: string): number {
  return Math.round((Date.parse(`${toDate}T00:00:00Z`) - Date.parse(`${fromDate}T00:00:00Z`)) / 86_400_000);
}

/** Whether the rule's time falling at `at` is an occurrence (only "every N days" ever says no). */
export function isRecurrenceOccurrenceDay(rule: TaskRecurrenceRule, at: number, timezone: string): boolean {
  if (rule.kind !== 'every_n_days') return true;
  const days = daysBetween(rule.anchorDate, localDateInZone(at, timezone));
  return days >= 0 && days % rule.everyDays === 0;
}

export type TaskOccurrenceDecision =
  | Readonly<{ kind: 'start'; thread: Readonly<{ kind: 'new' } | { kind: 'existing'; sessionId: string }>; closePrevious?: string }>
  /** `record`: whether the skip belongs in the task's history (a real occurrence that didn't run). */
  | Readonly<{ kind: 'skip'; record: boolean; reason: string }>;

/**
 * What a firing does. Occurrences never overlap: while the previous one still works (its thread has a
 * live presence record), the new one is skipped and recorded as such instead of waiting — a wait
 * would hold the Automation run open past its lease, and the next firing comes anyway. A previous
 * occurrence whose thread stopped without reporting is closed as interrupted.
 */
export function decideTaskOccurrence(params: Readonly<{
  task: AgentTaskV1;
  ruleId: string;
  now: number;
  isThreadWorking: (sessionId: string) => boolean;
}>): TaskOccurrenceDecision {
  const { task } = params;
  const recurrence = task.recurrence;
  if (!recurrence || recurrence.paused) return { kind: 'skip', record: false, reason: 'recurrence paused or removed' };
  if (task.status === 'done') return { kind: 'skip', record: false, reason: 'task is done' };
  if (task.archivedAt !== undefined) return { kind: 'skip', record: false, reason: 'task is archived' };
  const rule = recurrence.rules.find((entry) => entry.id === params.ruleId);
  if (!rule) return { kind: 'skip', record: false, reason: 'rule removed' };
  if (!isRecurrenceOccurrenceDay(rule, params.now, recurrence.timezone)) {
    return { kind: 'skip', record: false, reason: 'not an occurrence day' };
  }
  if (task.assignee.kind === 'user') return { kind: 'skip', record: true, reason: 'assigned to the user; only agents and sessions work recurring tasks' };

  const previous = [...(task.occurrences ?? [])].reverse().find((entry) => entry.status === 'running');
  let closePrevious: string | undefined;
  if (previous) {
    if (previous.sessionId && params.isThreadWorking(previous.sessionId)) {
      return { kind: 'skip', record: true, reason: `previous occurrence still running in ${previous.sessionId}` };
    }
    closePrevious = previous.id;
  }

  // A session assignee works every occurrence itself.
  if (task.assignee.kind === 'session') {
    return { kind: 'start', thread: { kind: 'existing', sessionId: task.assignee.sessionId }, ...(closePrevious ? { closePrevious } : {}) };
  }
  const lastThread = [...(task.occurrences ?? [])].reverse().find((entry) => entry.sessionId)?.sessionId ?? task.threads.at(-1);
  const thread = recurrence.continuity === 'same_thread' && lastThread
    ? { kind: 'existing' as const, sessionId: lastThread }
    : { kind: 'new' as const };
  return { kind: 'start', thread, ...(closePrevious ? { closePrevious } : {}) };
}

/** The message that puts the agent to work on one occurrence. */
export function buildTaskOccurrencePrompt(params: Readonly<{ task: AgentTaskV1; occurrenceId: string }>): string {
  const { task } = params;
  return [
    `Recurring task "${task.title}" is due now (task id ${task.id}, occurrence ${params.occurrenceId}).`,
    task.description ? `\n${task.description}` : '',
    task.source?.url || task.source?.label ? `\nSource: ${[task.source.label, task.source.url].filter(Boolean).join(' — ')}` : '',
    `\nWork on it now. When you finish, report the result with tarea_actualizar (taskId ${task.id}) and a short comment. The task repeats, so it stays open for the next occurrence; marking it done only records this occurrence's result.`,
  ].join('');
}

/**
 * A one-time start ("Schedule…" on a task assigned to an agent): one Automation whose cron names
 * that minute, day and month in the user's time zone, so the existing engine stays the only
 * scheduler and a sleeping machine runs it when it wakes. The daemon starts the task, clears the
 * schedule from the task and deletes the Automation; a later yearly firing finds no schedule and
 * does nothing. A start must therefore be within a year.
 */
export const TaskScheduledStartV1Schema = z.object({
  at: z.number(),
  timezone: z.string().min(1),
  automationId: z.string().optional(),
}).passthrough();
export type TaskScheduledStartV1 = z.infer<typeof TaskScheduledStartV1Schema>;

export function scheduledStartCron(at: number, timezone: string): string {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: timezone, month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', hourCycle: 'h23',
  }).formatToParts(new Date(at));
  const part = (type: string) => Number.parseInt(parts.find((entry) => entry.type === type)?.value ?? '0', 10);
  return `${part('minute')} ${part('hour')} ${part('day')} ${part('month')} *`;
}

export type ScheduledStartDecision = Readonly<{ kind: 'start' }> | Readonly<{ kind: 'skip'; reason: string }>;

/** Whether a scheduled-start firing still applies: the task must still hold this schedule. */
export function decideScheduledStart(params: Readonly<{ task: AgentTaskV1; automationId: string }>): ScheduledStartDecision {
  const { task } = params;
  if (task.scheduledStartV1?.automationId !== params.automationId) return { kind: 'skip', reason: 'schedule cancelled or moved' };
  if (task.status === 'done') return { kind: 'skip', reason: 'task is done' };
  if (task.archivedAt !== undefined) return { kind: 'skip', reason: 'task is archived' };
  if (task.assignee.kind === 'user') return { kind: 'skip', reason: 'task is assigned to the user' };
  return { kind: 'start' };
}

/** The message that puts the agent to work on a task it was scheduled to start. */
export function buildTaskStartPrompt(task: AgentTaskV1): string {
  return [
    `Task "${task.title}" was scheduled to start now (task id ${task.id}).`,
    task.description ? `\n${task.description}` : '',
    task.source?.url || task.source?.label ? `\nSource: ${[task.source.label, task.source.url].filter(Boolean).join(' — ')}` : '',
    task.dueAt ? `\nDue: ${new Date(task.dueAt).toISOString()}` : '',
    `\nWork on it now and keep it updated with tarea_actualizar (taskId ${task.id}).`,
  ].join('');
}

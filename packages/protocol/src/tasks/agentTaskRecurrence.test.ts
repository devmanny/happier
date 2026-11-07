import { describe, expect, it } from 'vitest';

import { parseAgentTaskV1, type AgentTaskV1 } from './agentTask.js';
import {
  buildTaskOccurrencePrompt,
  decideScheduledStart,
  decideTaskOccurrence,
  scheduledStartCron,
  isRecurrenceOccurrenceDay,
  recurrenceRuleCron,
  type TaskRecurrenceRule,
} from './agentTaskRecurrence.js';

const weekdays9: TaskRecurrenceRule = { id: 'r1', kind: 'weekly', weekdays: [1, 2, 3, 4, 5], time: '09:00' };
const weekend16: TaskRecurrenceRule = { id: 'r2', kind: 'weekly', weekdays: [6, 0], time: '16:00' };

function task(overrides: Partial<AgentTaskV1> = {}): AgentTaskV1 {
  return {
    v: 1, id: 't1', title: 'Revisión diaria', assignee: { kind: 'agent', agentId: 'a-mateo', name: 'Mateo' },
    status: 'todo', threads: [], log: [], createdAt: 0, updatedAt: 0, directory: '~/Projects/Radar', machineId: 'm1',
    recurrence: { v: 1, timezone: 'America/Mexico_City', continuity: 'new_thread', paused: false, rules: [weekdays9, weekend16] },
    ...overrides,
  };
}

describe('task recurrence rules', () => {
  it('turns each rule into one cron in the user\'s time zone (L–V 9:00 and S–D 16:00 in the same task)', () => {
    expect(recurrenceRuleCron(weekdays9)).toBe('0 9 * * 1,2,3,4,5');
    expect(recurrenceRuleCron(weekend16)).toBe('0 16 * * 0,6');
    expect(recurrenceRuleCron({ id: 'r3', kind: 'monthly', dayOfMonth: 15, time: '08:30' })).toBe('30 8 15 * *');
    // Every N days fires daily at that time; the occurrence day is decided against its anchor.
    expect(recurrenceRuleCron({ id: 'r4', kind: 'every_n_days', everyDays: 3, anchorDate: '2026-11-07', time: '07:05' })).toBe('5 7 * * *');
  });

  it('decides "every N days" from the anchor date in the task\'s time zone', () => {
    const rule: TaskRecurrenceRule = { id: 'r4', kind: 'every_n_days', everyDays: 3, anchorDate: '2026-11-07', time: '07:00' };
    const at = (iso: string) => Date.parse(iso);
    expect(isRecurrenceOccurrenceDay(rule, at('2026-11-07T13:00:00Z'), 'America/Mexico_City')).toBe(true);
    expect(isRecurrenceOccurrenceDay(rule, at('2026-11-08T13:00:00Z'), 'America/Mexico_City')).toBe(false);
    expect(isRecurrenceOccurrenceDay(rule, at('2026-11-10T13:00:00Z'), 'America/Mexico_City')).toBe(true);
    // 05:30 UTC on the 10th is still the 9th in Mexico City.
    expect(isRecurrenceOccurrenceDay(rule, at('2026-11-10T05:30:00Z'), 'America/Mexico_City')).toBe(false);
    expect(isRecurrenceOccurrenceDay(weekdays9, 0, 'UTC')).toBe(true);
  });

  it('parses a task with recurrence and its occurrence history', () => {
    const withHistory = task({ occurrences: [{ id: 'run1', ruleId: 'r1', startedAt: 1, sessionId: 's1', status: 'running' }] });
    expect(parseAgentTaskV1(withHistory)).toEqual(withHistory);
    expect(parseAgentTaskV1({ ...task(), recurrence: { ...task().recurrence, rules: [{ id: 'x', kind: 'weekly', weekdays: [], time: '9:00' }] } })).toBeNull();
  });
});

describe('deciding an occurrence', () => {
  const now = Date.parse('2026-11-09T15:00:00Z');

  it('starts a new thread, or continues the last one when the task asks for it', () => {
    expect(decideTaskOccurrence({ task: task(), ruleId: 'r1', now, isThreadWorking: () => false }))
      .toEqual({ kind: 'start', thread: { kind: 'new' } });
    const same = task({
      recurrence: { ...task().recurrence!, continuity: 'same_thread' },
      occurrences: [{ id: 'run0', ruleId: 'r1', startedAt: 1, sessionId: 's-prev', status: 'completed', finishedAt: 2 }],
    });
    expect(decideTaskOccurrence({ task: same, ruleId: 'r1', now, isThreadWorking: () => false }))
      .toEqual({ kind: 'start', thread: { kind: 'existing', sessionId: 's-prev' } });
  });

  it('skips (and records it) while the previous occurrence is still working, and closes one that stopped unreported', () => {
    const running = task({ occurrences: [{ id: 'run0', ruleId: 'r1', startedAt: 1, sessionId: 's-prev', status: 'running' }] });
    expect(decideTaskOccurrence({ task: running, ruleId: 'r1', now, isThreadWorking: (id) => id === 's-prev' }))
      .toEqual({ kind: 'skip', record: true, reason: 'previous occurrence still running in s-prev' });
    expect(decideTaskOccurrence({ task: running, ruleId: 'r1', now, isThreadWorking: () => false }))
      .toEqual({ kind: 'start', thread: { kind: 'new' }, closePrevious: 'run0' });
  });

  it('does nothing for a paused, finished, deleted-rule or user-assigned task, or an off day', () => {
    const quiet = (t: AgentTaskV1, ruleId = 'r1') => decideTaskOccurrence({ task: t, ruleId, now, isThreadWorking: () => false });
    expect(quiet(task({ recurrence: { ...task().recurrence!, paused: true } }))).toMatchObject({ kind: 'skip', record: false });
    expect(quiet(task({ status: 'done' }))).toMatchObject({ kind: 'skip', record: false });
    expect(quiet(task(), 'gone')).toMatchObject({ kind: 'skip', record: false });
    expect(quiet(task({ assignee: { kind: 'user' } }))).toMatchObject({ kind: 'skip', record: true });
    const everyThird = task({ recurrence: { ...task().recurrence!, rules: [{ id: 'r9', kind: 'every_n_days', everyDays: 3, anchorDate: '2026-11-07', time: '09:00' }] } });
    expect(quiet(everyThird, 'r9')).toMatchObject({ kind: 'skip', record: false, reason: 'not an occurrence day' });
  });

  it('gives the agent the task to work on, with its id to report back', () => {
    const prompt = buildTaskOccurrencePrompt({ task: task({ description: 'Revisa errores de la noche.' }), occurrenceId: 'run1' });
    expect(prompt).toContain('Revisión diaria');
    expect(prompt).toContain('Revisa errores de la noche.');
    expect(prompt).toContain('tarea_actualizar');
    expect(prompt).toContain('t1');
  });
});

describe('scheduled start', () => {
  it('turns a one-time start into a cron for that minute, day and month in the time zone', () => {
    expect(scheduledStartCron(Date.parse('2026-11-12T16:30:00Z'), 'America/Mexico_City')).toBe('30 10 12 11 *');
    expect(scheduledStartCron(Date.parse('2026-12-31T23:05:00Z'), 'UTC')).toBe('5 23 31 12 *');
  });

  it('starts only the schedule the task still has, and only once', () => {
    const scheduled = task({ recurrence: undefined, scheduledStartV1: { at: 5, timezone: 'UTC', automationId: 'auto-1' } });
    expect(decideScheduledStart({ task: scheduled, automationId: 'auto-1' })).toEqual({ kind: 'start' });
    expect(decideScheduledStart({ task: scheduled, automationId: 'auto-old' })).toMatchObject({ kind: 'skip' });
    expect(decideScheduledStart({ task: task({ recurrence: undefined }), automationId: 'auto-1' })).toMatchObject({ kind: 'skip' });
    expect(decideScheduledStart({ task: { ...scheduled, status: 'done' }, automationId: 'auto-1' })).toMatchObject({ kind: 'skip' });
    expect(decideScheduledStart({ task: { ...scheduled, assignee: { kind: 'user' } }, automationId: 'auto-1' })).toMatchObject({ kind: 'skip' });
    expect(decideScheduledStart({ task: { ...scheduled, assignee: { kind: 'session', sessionId: 's1' } }, automationId: 'auto-1' })).toEqual({ kind: 'start' });
  });

  it('parses a scheduled start on a task', () => {
    const scheduled = task({ scheduledStartV1: { at: 5, timezone: 'UTC', automationId: 'auto-1' } });
    expect(parseAgentTaskV1(scheduled)).toEqual(scheduled);
  });
});

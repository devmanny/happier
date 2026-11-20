import {
  AGENT_TASK_STATUSES,
  applyAgentTaskUpdate,
  isAgentTaskWorkedBy,
  type AgentIdentityV1,
  type AgentTaskActor,
  type AgentTaskAssignee,
  type AgentTaskSource,
  type AgentTaskStatus,
  type AgentTaskUpdate,
} from '@happier-dev/protocol';

import type { AgentTaskStore } from './agentTaskStore';

export type AgentTaskCaller = Readonly<{
  agent: Pick<AgentIdentityV1, 'id' | 'name' | 'emoji'> | null;
  sessionId: string;
}>;

class TaskInputError extends Error {}

function readString(input: Record<string, unknown>, key: string): string | undefined {
  const value = input[key];
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : undefined;
}

function readStatus(input: Record<string, unknown>): AgentTaskStatus | undefined {
  const status = readString(input, 'status');
  if (status === undefined) return undefined;
  if (!(AGENT_TASK_STATUSES as readonly string[]).includes(status)) {
    throw new TaskInputError(`status must be one of ${AGENT_TASK_STATUSES.join(', ')}`);
  }
  return status as AgentTaskStatus;
}

/** An ISO 8601 date (or epoch ms); undefined when absent, null when given empty (to clear it). */
function readDate(input: Record<string, unknown>, key: 'startAt' | 'dueAt'): number | null | undefined {
  const raw = input[key];
  if (raw === undefined) return undefined;
  if (raw === '' || raw === null) return null;
  const parsed = typeof raw === 'number' ? raw : typeof raw === 'string' ? Date.parse(raw) : Number.NaN;
  if (!Number.isFinite(parsed)) throw new TaskInputError(`${key} must be an ISO 8601 date such as 2026-11-10T18:00:00-06:00`);
  return parsed;
}

function readAssignee(input: Record<string, unknown>, caller: AgentTaskCaller): AgentTaskAssignee | undefined {
  const raw = readString(input, 'assignee');
  if (raw === undefined) return undefined;
  const lowered = raw.toLowerCase();
  if (lowered === 'user' || lowered === 'manny') return { kind: 'user' };
  if (lowered === 'me') {
    // A session without an agent works the task itself.
    if (!caller.agent) return { kind: 'session', sessionId: caller.sessionId };
    return { kind: 'agent', agentId: caller.agent.id, name: caller.agent.name, ...(caller.agent.emoji ? { emoji: caller.agent.emoji } : {}) };
  }
  return { kind: 'agent', agentId: raw };
}

function readSource(input: Record<string, unknown>): AgentTaskSource | undefined {
  const kind = readString(input, 'sourceKind');
  const label = readString(input, 'sourceLabel');
  const url = readString(input, 'sourceUrl');
  if (!kind && !label && !url) return undefined;
  const sourceKind = (['chat', 'email', 'session', 'other'] as const).find((value) => value === kind) ?? 'other';
  return { kind: sourceKind, ...(label ? { label } : {}), ...(url ? { url } : {}) };
}

/** The caller works the task (and is linked to it as a thread) when it is for its agent or for the session itself. */
function works(caller: AgentTaskCaller, assignee: AgentTaskAssignee): boolean {
  return isAgentTaskWorkedBy(assignee, { agentId: caller.agent?.id, sessionId: caller.sessionId });
}

function actor(caller: AgentTaskCaller): AgentTaskActor {
  return caller.agent
    ? { kind: 'agent', agentId: caller.agent.id, sessionId: caller.sessionId }
    : { kind: 'session', sessionId: caller.sessionId };
}

/** `tarea_crear` and `tarea_actualizar`, run in the calling session's runner. */
export async function runAgentTaskTool(params: Readonly<{
  store: AgentTaskStore;
  caller: AgentTaskCaller;
  operation: 'create' | 'update';
  input: Record<string, unknown>;
}>): Promise<Record<string, unknown>> {
  const { store, caller, input } = params;
  try {
    if (params.operation === 'create') {
      const title = readString(input, 'title');
      if (!title) return { ok: false, error: 'title is required' };
      const assignee = readAssignee(input, caller)
        ?? (caller.agent ? readAssignee({ assignee: 'me' }, caller)! : { kind: 'user' as const });
      const startAt = readDate(input, 'startAt');
      const dueAt = readDate(input, 'dueAt');
      const description = readString(input, 'description');
      const directory = readString(input, 'directory');
      const machineId = readString(input, 'machineId');
      // It came from this session, whatever else it came from (a chat, an email).
      const source: AgentTaskSource = { ...(readSource(input) ?? { kind: 'session' }), sessionId: caller.sessionId };
      const task = await store.create({
        title,
        assignee,
        status: readStatus(input) ?? 'todo',
        threads: works(caller, assignee) ? [caller.sessionId] : [],
        createdBy: actor(caller),
        source,
        ...(description ? { description } : {}),
        ...(typeof startAt === 'number' ? { startAt } : {}),
        ...(typeof dueAt === 'number' ? { dueAt } : {}),
        ...(directory ? { directory } : {}),
        ...(machineId ? { machineId } : {}),
      });
      return { ok: true, taskId: task.id, assignee: task.assignee, status: task.status };
    }

    const taskId = readString(input, 'taskId');
    if (!taskId) return { ok: false, error: 'taskId is required' };
    const startAt = readDate(input, 'startAt');
    const dueAt = readDate(input, 'dueAt');
    const assignee = readAssignee(input, caller);
    const status = readStatus(input);
    const title = readString(input, 'title');
    const comment = readString(input, 'comment');
    const current = await store.get(taskId);
    if (!current) return { ok: false, error: `task ${taskId} not found` };
    const update: AgentTaskUpdate = {
      ...(status ? { status } : {}),
      ...(title ? { title } : {}),
      ...(comment ? { comment } : {}),
      ...(assignee ? { assignee } : {}),
      ...(startAt !== undefined ? { startAt } : {}),
      ...(dueAt !== undefined ? { dueAt } : {}),
      ...(typeof input.description === 'string' ? { description: input.description.trim() || null } : {}),
      ...(typeof input.directory === 'string' ? { directory: input.directory.trim() || null } : {}),
      by: actor(caller),
      ...(works(caller, assignee ?? current.task.assignee) ? { threadSessionId: caller.sessionId } : {}),
    };

    // A repeating task stays open for its next occurrence: only the user closes or pauses it.
    // An agent's "done" is the result of the occurrence its thread is working.
    if (status === 'done' && current.task.recurrence && !current.task.recurrence.paused) {
      const occurrence = (current.task.occurrences ?? []).find((entry) => entry.status === 'running' && entry.sessionId === caller.sessionId);
      if (!occurrence) {
        return {
          ok: false,
          error: 'This task repeats, so only the user can close or pause it. Report the result of your occurrence with a comment instead.',
        };
      }
      const { status: _done, ...rest } = update;
      const task = await store.update(taskId, (latest, now) => {
        const updated = applyAgentTaskUpdate(latest, rest, now);
        return {
          ...updated,
          occurrences: (updated.occurrences ?? []).map((entry) => (entry.id === occurrence.id && entry.status === 'running'
            ? { ...entry, status: 'completed' as const, finishedAt: now, ...(comment ? { note: comment } : {}) }
            : entry)),
        };
      });
      if (!task) return { ok: false, error: `task ${taskId} not found` };
      return {
        ok: true,
        taskId: task.id,
        status: task.status,
        occurrence: { id: occurrence.id, status: 'completed' },
        message: 'This task repeats: your result was recorded on this occurrence and the task stays open for the next one. Only the user closes or pauses it.',
      };
    }

    const task = await store.applyUpdate(taskId, update);
    if (!task) return { ok: false, error: `task ${taskId} not found` };
    return { ok: true, taskId: task.id, status: task.status };
  } catch (error) {
    if (error instanceof TaskInputError) return { ok: false, error: error.message };
    throw error;
  }
}

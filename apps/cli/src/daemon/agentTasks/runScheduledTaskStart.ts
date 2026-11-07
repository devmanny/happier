import {
  buildTaskStartPrompt,
  decideScheduledStart,
  type AgentProfileV1,
  type AgentTaskV1,
} from '@happier-dev/protocol';

import type { AgentTaskStore } from '@/session/agentTasks/agentTaskStore';

import { spawnForTask, type TaskOccurrenceDeps, type TaskOccurrenceResult } from './runTaskOccurrence';

export type ScheduledStartDeps = Pick<TaskOccurrenceDeps, 'readAgentProfile' | 'startNewThread' | 'continueThread' | 'defaultPermissionMode'> & Readonly<{
  store: AgentTaskStore;
  /** Removes the one-time Automation once it has fired (`DELETE /v2/automations/:id`). */
  deleteAutomation: (automationId: string) => Promise<void>;
}>;

function finish(task: AgentTaskV1, at: number, note: string, sessionId?: string): AgentTaskV1 {
  const { scheduledStartV1: _done, ...rest } = task;
  return {
    ...rest,
    ...(sessionId && !task.threads.includes(sessionId) ? { threads: [...task.threads, sessionId] } : {}),
    ...(sessionId && task.status === 'todo' ? { status: 'in_progress' as const } : {}),
    log: [...task.log, { at, by: { kind: 'user' as const }, text: note, ...(sessionId && task.status === 'todo' ? { status: 'in_progress' as const } : {}) }],
    updatedAt: at,
  };
}

/**
 * A task's one-time scheduled start (an Automation run claimed by this daemon): the assigned agent
 * opens a thread on it, or the assigned session is sent the task. The schedule is cleared from the
 * task and the Automation removed, so it never fires again.
 */
export async function runScheduledTaskStart(
  run: Readonly<{ runId: string; automationId: string; taskId: string }>,
  deps: ScheduledStartDeps,
): Promise<TaskOccurrenceResult> {
  const removeAutomation = () => deps.deleteAutomation(run.automationId).catch(() => undefined);
  const current = await deps.store.get(run.taskId);
  if (!current || decideScheduledStart({ task: current.task, automationId: run.automationId }).kind === 'skip') {
    await removeAutomation();
    return { type: 'success' };
  }
  const task = current.task;
  const prompt = buildTaskStartPrompt(task);
  let started: Readonly<{ ok: true; sessionId: string }> | Readonly<{ ok: false; code: string; message: string }>;
  if (task.assignee.kind === 'session') {
    const sessionId = task.assignee.sessionId;
    const sent = await deps.continueThread(sessionId, prompt, run.runId);
    started = sent.ok ? { ok: true, sessionId } : { ok: false, code: sent.code, message: `could not send the task to ${sessionId}` };
  } else if (task.assignee.kind === 'agent' && task.directory) {
    const profile: AgentProfileV1 | null = await deps.readAgentProfile(task.assignee.agentId);
    started = profile
      ? await deps.startNewThread(spawnForTask(task, profile, deps.defaultPermissionMode(profile.providerId)), prompt, run.runId)
      : { ok: false, code: 'agent_profile_missing', message: `agent ${task.assignee.agentId} not found` };
  } else {
    started = { ok: false, code: 'task_not_runnable', message: 'the task needs an agent with a folder, or a session' };
  }

  await deps.store.update(run.taskId, (latest, at) => (started.ok
    ? finish(latest, at, 'Scheduled start: work began.', started.sessionId)
    : finish(latest, at, `Scheduled start failed: ${started.message}`)));
  await removeAutomation();
  return started.ok
    ? { type: 'success', sessionId: started.sessionId }
    : { type: 'failed', errorCode: started.code, errorMessage: started.message };
}

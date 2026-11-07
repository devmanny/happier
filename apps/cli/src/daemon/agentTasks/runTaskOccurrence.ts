import {
  agentIdentityFromProfile,
  buildTaskOccurrencePrompt,
  decideTaskOccurrence,
  type AgentIdentityV1,
  type AgentProfileV1,
  type AgentTaskV1,
  type TaskOccurrence,
} from '@happier-dev/protocol';

import type { AgentTaskStore } from '@/session/agentTasks/agentTaskStore';

/** What a new occurrence thread is spawned with: the agent's identity, account and engine. */
export type TaskOccurrenceSpawn = Readonly<{
  directory: string;
  backendTarget: Readonly<{ kind: 'builtInAgent'; agentId: string }>;
  agentIdentity: AgentIdentityV1;
  environmentVariables?: Record<string, string>;
  modelId?: string;
  effort?: string;
  permissionMode?: string;
}>;

export type TaskOccurrenceDeps = Readonly<{
  store: AgentTaskStore;
  now?: () => number;
  readAgentProfile: (agentId: string) => Promise<AgentProfileV1 | null>;
  /** Sessions with a live presence record: a turn is running there right now. */
  liveThreadIds: () => Promise<ReadonlySet<string>>;
  startNewThread: (spawn: TaskOccurrenceSpawn, firstMessage: string, occurrenceId: string) => Promise<
    Readonly<{ ok: true; sessionId: string }> | Readonly<{ ok: false; code: string; message: string }>
  >;
  continueThread: (sessionId: string, message: string, occurrenceId: string) => Promise<
    Readonly<{ ok: true }> | Readonly<{ ok: false; code: string }>
  >;
  /** The account's default permission mode for new sessions with this provider, as the apps use it. */
  defaultPermissionMode: (providerId: string) => string | undefined;
}>;

export type TaskOccurrenceResult =
  | Readonly<{ type: 'success'; sessionId?: string }>
  | Readonly<{ type: 'failed'; errorCode: string; errorMessage: string }>;

/** Appends (or replaces, for the same run) an occurrence; closes the previous one when asked. */
function recordOccurrence(
  task: AgentTaskV1,
  occurrence: TaskOccurrence,
  now: number,
  closePrevious?: string,
): AgentTaskV1 {
  const history = (task.occurrences ?? [])
    .filter((entry) => entry.id !== occurrence.id)
    .map((entry) => (entry.id === closePrevious && entry.status === 'running'
      ? { ...entry, status: 'interrupted' as const, finishedAt: now, note: 'its thread stopped without reporting' }
      : entry));
  const threads = occurrence.sessionId && !task.threads.includes(occurrence.sessionId)
    ? [...task.threads, occurrence.sessionId]
    : task.threads;
  return {
    ...task,
    occurrences: [...history, occurrence],
    threads,
    ...(occurrence.status === 'running' && task.status === 'todo' ? { status: 'in_progress' as const } : {}),
    updatedAt: now,
  };
}

export function spawnForTask(task: AgentTaskV1, profile: AgentProfileV1, permissionMode: string | undefined): TaskOccurrenceSpawn {
  const configDir = profile.account.configDir?.trim();
  return {
    directory: task.directory!,
    backendTarget: { kind: 'builtInAgent', agentId: profile.providerId },
    agentIdentity: agentIdentityFromProfile(profile),
    ...(profile.providerId === 'claude' && configDir ? { environmentVariables: { CLAUDE_CONFIG_DIR: configDir } } : {}),
    ...(profile.modelId && profile.modelId !== 'default' ? { modelId: profile.modelId } : {}),
    ...(profile.effort ? { effort: profile.effort } : {}),
    ...(permissionMode ? { permissionMode } : {}),
  };
}

/**
 * Works one firing of a recurring task's rule (an Automation run claimed by this daemon): decide,
 * start or continue the agent's thread, and keep the result in the task's history.
 */
export async function runTaskOccurrence(
  run: Readonly<{ runId: string; dueAt?: number; taskId: string; ruleId: string }>,
  deps: TaskOccurrenceDeps,
): Promise<TaskOccurrenceResult> {
  const now = deps.now?.() ?? Date.now();
  const current = await deps.store.get(run.taskId);
  if (!current) return { type: 'success' };
  const task = current.task;
  if (task.occurrences?.some((entry) => entry.id === run.runId && entry.status !== 'failed')) {
    return { type: 'success', ...(task.occurrences.find((entry) => entry.id === run.runId)?.sessionId
      ? { sessionId: task.occurrences.find((entry) => entry.id === run.runId)!.sessionId! } : {}) };
  }

  const live = await deps.liveThreadIds();
  const decision = decideTaskOccurrence({ task, ruleId: run.ruleId, now, isThreadWorking: (id) => live.has(id) });
  const base = { id: run.runId, ruleId: run.ruleId, ...(run.dueAt !== undefined ? { dueAt: run.dueAt } : {}), startedAt: now };
  const save = (occurrence: TaskOccurrence, closePrevious?: string) =>
    deps.store.update(run.taskId, (latest, at) => recordOccurrence(latest, occurrence, at, closePrevious));

  if (decision.kind === 'skip') {
    if (decision.record) await save({ ...base, status: 'skipped', finishedAt: now, note: decision.reason });
    return { type: 'success' };
  }
  // A session assignee: every occurrence is sent to that session (no agent profile or folder needed).
  if (task.assignee.kind === 'session' && decision.thread.kind === 'existing') {
    const sessionId = decision.thread.sessionId;
    const sent = await deps.continueThread(sessionId, buildTaskOccurrencePrompt({ task, occurrenceId: run.runId }), run.runId);
    if (!sent.ok) {
      await save({ ...base, sessionId, status: 'failed', finishedAt: now, note: `could not send it to ${sessionId} (${sent.code})` }, decision.closePrevious);
      return { type: 'failed', errorCode: sent.code, errorMessage: `could not send the occurrence to session ${sessionId}` };
    }
    await save({ ...base, sessionId, status: 'running' }, decision.closePrevious);
    return { type: 'success', sessionId };
  }
  if (task.assignee.kind !== 'agent' || !task.directory) {
    await save({ ...base, status: 'failed', finishedAt: now, note: 'the task needs an agent and a folder to repeat' });
    return { type: 'failed', errorCode: 'task_not_runnable', errorMessage: 'recurring task needs an agent assignee and a folder' };
  }
  const profile = await deps.readAgentProfile(task.assignee.agentId);
  if (!profile) {
    await save({ ...base, status: 'failed', finishedAt: now, note: `agent ${task.assignee.agentId} not found` }, decision.closePrevious);
    return { type: 'failed', errorCode: 'agent_profile_missing', errorMessage: `agent profile ${task.assignee.agentId} not found` };
  }

  const prompt = buildTaskOccurrencePrompt({ task, occurrenceId: run.runId });
  let note: string | undefined;
  if (decision.thread.kind === 'existing') {
    const continued = await deps.continueThread(decision.thread.sessionId, prompt, run.runId);
    if (continued.ok) {
      await save({ ...base, sessionId: decision.thread.sessionId, status: 'running' }, decision.closePrevious);
      return { type: 'success', sessionId: decision.thread.sessionId };
    }
    note = `could not continue ${decision.thread.sessionId} (${continued.code}); opened a new thread`;
  }

  const started = await deps.startNewThread(spawnForTask(task, profile, deps.defaultPermissionMode(profile.providerId)), prompt, run.runId);
  if (!started.ok) {
    await save({ ...base, status: 'failed', finishedAt: now, note: `${started.code}: ${started.message}` }, decision.closePrevious);
    return { type: 'failed', errorCode: started.code, errorMessage: started.message };
  }
  await save({ ...base, sessionId: started.sessionId, status: 'running', ...(note ? { note } : {}) }, decision.closePrevious);
  return { type: 'success', sessionId: started.sessionId };
}

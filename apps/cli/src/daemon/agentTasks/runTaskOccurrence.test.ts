import { describe, expect, it, vi } from 'vitest';

import type { AgentProfileV1, AgentTaskV1 } from '@happier-dev/protocol';

import { createInMemoryAccountKv } from '@/api/kv/inMemoryAccountKv.testkit';
import { AgentTaskStore } from '@/session/agentTasks/agentTaskStore';

import { runTaskOccurrence, type TaskOccurrenceDeps } from './runTaskOccurrence';

const material = { type: 'dataKey', machineKey: new Uint8Array(32).fill(3) } as const;
const NOW = Date.parse('2026-11-09T15:00:00Z');

const mateo: AgentProfileV1 = {
  v: 1, id: 'a-mateo', name: 'Mateo', emoji: '🤖', description: 'Firma como Mateo.', providerId: 'claude',
  modelId: 'claude-opus-5-5', effort: 'high', account: { label: 'Claude Nómada', configDir: '~/.claude-mateo' }, updatedAt: 1,
};

async function setup(overrides: Partial<AgentTaskV1> = {}) {
  const kv = createInMemoryAccountKv();
  const store = new AgentTaskStore({ transport: kv.transport, material, now: () => NOW, newId: () => 't1' });
  await store.create({
    title: 'Revisión diaria', assignee: { kind: 'agent', agentId: 'a-mateo', name: 'Mateo' }, status: 'todo', threads: [],
    directory: '/repo', machineId: 'm1',
    recurrence: { v: 1, timezone: 'America/Mexico_City', continuity: 'new_thread', paused: false,
      rules: [{ id: 'r1', kind: 'weekly', weekdays: [1, 2, 3, 4, 5], time: '09:00' }] },
    ...overrides,
  });
  const deps: TaskOccurrenceDeps = {
    store,
    now: () => NOW,
    readAgentProfile: vi.fn(async () => mateo),
    liveThreadIds: vi.fn(async () => new Set<string>()),
    startNewThread: vi.fn(async () => ({ ok: true as const, sessionId: 's-new' })),
    continueThread: vi.fn(async () => ({ ok: true as const })),
    defaultPermissionMode: () => 'yolo',
  };
  return { store, deps };
}

describe('runTaskOccurrence', () => {
  it('opens a thread as the agent, with its account, engine and the task as the first message', async () => {
    const { store, deps } = await setup();
    const result = await runTaskOccurrence({ runId: 'run1', dueAt: NOW, taskId: 't1', ruleId: 'r1' }, deps);
    expect(result).toEqual({ type: 'success', sessionId: 's-new' });
    expect(deps.startNewThread).toHaveBeenCalledWith(expect.objectContaining({
      directory: '/repo',
      backendTarget: { kind: 'builtInAgent', agentId: 'claude' },
      agentIdentity: { v: 1, id: 'a-mateo', name: 'Mateo', emoji: '🤖', description: 'Firma como Mateo.' },
      environmentVariables: { CLAUDE_CONFIG_DIR: '~/.claude-mateo' },
      modelId: 'claude-opus-5-5',
      permissionMode: 'yolo',
    }), expect.stringContaining('Revisión diaria'), 'run1');
    const { task } = (await store.get('t1'))!;
    expect(task.occurrences).toEqual([{ id: 'run1', ruleId: 'r1', dueAt: NOW, startedAt: NOW, sessionId: 's-new', status: 'running' }]);
    expect(task).toMatchObject({ status: 'in_progress', threads: ['s-new'] });

    // The same run delivered twice (lease takeover) is recorded once.
    await runTaskOccurrence({ runId: 'run1', dueAt: NOW, taskId: 't1', ruleId: 'r1' }, deps);
    expect((await store.get('t1'))!.task.occurrences).toHaveLength(1);
  });

  it('continues the last thread when the task asks for it, and opens a new one if that fails', async () => {
    const { store, deps } = await setup({
      recurrence: { v: 1, timezone: 'UTC', continuity: 'same_thread', paused: false, rules: [{ id: 'r1', kind: 'weekly', weekdays: [1], time: '09:00' }] },
      occurrences: [{ id: 'run0', ruleId: 'r1', startedAt: 1, finishedAt: 2, sessionId: 's-prev', status: 'completed' }],
    });
    expect(await runTaskOccurrence({ runId: 'run1', taskId: 't1', ruleId: 'r1' }, deps)).toEqual({ type: 'success', sessionId: 's-prev' });
    expect(deps.continueThread).toHaveBeenCalledWith('s-prev', expect.stringContaining('Revisión diaria'), 'run1');
    expect(deps.startNewThread).not.toHaveBeenCalled();

    vi.mocked(deps.continueThread).mockResolvedValueOnce({ ok: false, code: 'session_archived' });
    expect(await runTaskOccurrence({ runId: 'run2', taskId: 't1', ruleId: 'r1' }, deps)).toEqual({ type: 'success', sessionId: 's-new' });
    expect((await store.get('t1'))!.task.occurrences?.at(-1)).toMatchObject({ id: 'run2', sessionId: 's-new', note: expect.stringContaining('session_archived') });
  });

  it('sends each occurrence of a session-assigned task to that session, and fails without opening another thread', async () => {
    const { store, deps } = await setup({ assignee: { kind: 'session', sessionId: 's-chat', title: 'Navegador' }, directory: undefined });
    expect(await runTaskOccurrence({ runId: 'run1', taskId: 't1', ruleId: 'r1' }, deps)).toEqual({ type: 'success', sessionId: 's-chat' });
    expect(deps.continueThread).toHaveBeenCalledWith('s-chat', expect.stringContaining('Revisión diaria'), 'run1');
    expect(deps.readAgentProfile).not.toHaveBeenCalled();
    expect((await store.get('t1'))!.task.occurrences?.at(-1)).toMatchObject({ id: 'run1', sessionId: 's-chat', status: 'running' });

    vi.mocked(deps.continueThread).mockResolvedValueOnce({ ok: false, code: 'session_archived' });
    expect(await runTaskOccurrence({ runId: 'run2', taskId: 't1', ruleId: 'r1' }, deps)).toMatchObject({ type: 'failed' });
    expect(deps.startNewThread).not.toHaveBeenCalled();
    expect((await store.get('t1'))!.task.occurrences?.at(-1)).toMatchObject({ id: 'run2', status: 'failed' });
  });

  it('records a skip instead of starting on top of an occurrence that is still working', async () => {
    const { store, deps } = await setup({ occurrences: [{ id: 'run0', ruleId: 'r1', startedAt: 1, sessionId: 's-busy', status: 'running' }] });
    vi.mocked(deps.liveThreadIds).mockResolvedValue(new Set(['s-busy']));
    expect(await runTaskOccurrence({ runId: 'run1', taskId: 't1', ruleId: 'r1' }, deps)).toEqual({ type: 'success' });
    expect(deps.startNewThread).not.toHaveBeenCalled();
    expect((await store.get('t1'))!.task.occurrences?.at(-1)).toMatchObject({ id: 'run1', status: 'skipped', note: expect.stringContaining('s-busy') });
  });

  it('closes an occurrence whose thread stopped without reporting, then starts', async () => {
    const { store, deps } = await setup({ occurrences: [{ id: 'run0', ruleId: 'r1', startedAt: 1, sessionId: 's-gone', status: 'running' }] });
    await runTaskOccurrence({ runId: 'run1', taskId: 't1', ruleId: 'r1' }, deps);
    const occurrences = (await store.get('t1'))!.task.occurrences!;
    expect(occurrences.map((o) => [o.id, o.status])).toEqual([['run0', 'interrupted'], ['run1', 'running']]);
  });

  it('fails the run and records it when the agent profile is gone, and leaves no trace for a paused task', async () => {
    const { store, deps } = await setup();
    vi.mocked(deps.readAgentProfile).mockResolvedValueOnce(null);
    expect(await runTaskOccurrence({ runId: 'run1', taskId: 't1', ruleId: 'r1' }, deps)).toMatchObject({ type: 'failed', errorCode: 'agent_profile_missing' });
    expect((await store.get('t1'))!.task.occurrences?.at(-1)).toMatchObject({ id: 'run1', status: 'failed' });

    const paused = await setup({ recurrence: { v: 1, timezone: 'UTC', continuity: 'new_thread', paused: true, rules: [{ id: 'r1', kind: 'weekly', weekdays: [1], time: '09:00' }] } });
    expect(await runTaskOccurrence({ runId: 'run9', taskId: 't1', ruleId: 'r1' }, paused.deps)).toEqual({ type: 'success' });
    expect((await paused.store.get('t1'))!.task.occurrences).toBeUndefined();
  });
});

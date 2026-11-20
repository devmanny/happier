import { describe, expect, it, vi } from 'vitest';

import type { AgentProfileV1, AgentTaskV1 } from '@happier-dev/protocol';

import { createInMemoryAccountKv } from '@/api/kv/inMemoryAccountKv.testkit';
import { AgentTaskStore } from '@/session/agentTasks/agentTaskStore';

import { runScheduledTaskStart, type ScheduledStartDeps } from './runScheduledTaskStart';

const material = { type: 'dataKey', machineKey: new Uint8Array(32).fill(7) } as const;
const mateo: AgentProfileV1 = { v: 1, id: 'a-mateo', name: 'Mateo', providerId: 'codex', account: { label: 'ChatGPT' }, updatedAt: 1 };

async function setup(overrides: Partial<AgentTaskV1> = {}) {
  const kv = createInMemoryAccountKv();
  const store = new AgentTaskStore({ transport: kv.transport, material, now: () => 1_000, newId: () => 't1' });
  await store.create({
    title: 'Revisar la propuesta', assignee: { kind: 'agent', agentId: 'a-mateo', name: 'Mateo' }, status: 'todo', threads: [],
    directory: '/repo', machineId: 'm1', scheduledStartV1: { at: 900, timezone: 'UTC', automationId: 'auto-1' }, ...overrides,
  });
  const deps: ScheduledStartDeps = {
    store,
    readAgentProfile: vi.fn(async () => mateo),
    startNewThread: vi.fn(async () => ({ ok: true as const, sessionId: 's-new' })),
    continueThread: vi.fn(async () => ({ ok: true as const })),
    deleteAutomation: vi.fn(async () => {}),
  };
  return { store, deps };
}

describe('runScheduledTaskStart', () => {
  it('starts the agent on the task once, clears the schedule and removes its Automation', async () => {
    const { store, deps } = await setup();
    expect(await runScheduledTaskStart({ runId: 'run1', automationId: 'auto-1', taskId: 't1' }, deps)).toEqual({ type: 'success', sessionId: 's-new' });
    expect(deps.startNewThread).toHaveBeenCalledWith(expect.objectContaining({ directory: '/repo', backendTarget: { kind: 'builtInAgent', agentId: 'codex' }, permissionMode: 'yolo' }),
      expect.stringContaining('Revisar la propuesta'), 'run1');
    const { task } = (await store.get('t1'))!;
    expect(task).toMatchObject({ status: 'in_progress', threads: ['s-new'] });
    expect(task).not.toHaveProperty('scheduledStartV1');
    expect(task.log.at(-1)?.text).toContain('Scheduled start');
    expect(deps.deleteAutomation).toHaveBeenCalledWith('auto-1');
  });

  it('opens the agent\'s thread with the task\'s permission mode', async () => {
    const { deps } = await setup({ permissionMode: 'auto' });
    await runScheduledTaskStart({ runId: 'run5', automationId: 'auto-1', taskId: 't1' }, deps);
    expect(deps.startNewThread).toHaveBeenCalledWith(expect.objectContaining({ permissionMode: 'safe-yolo' }), expect.any(String), 'run5');
  });

  it('does nothing for a cancelled or moved schedule, but still removes the stray Automation', async () => {
    const { store, deps } = await setup();
    expect(await runScheduledTaskStart({ runId: 'run2', automationId: 'auto-old', taskId: 't1' }, deps)).toEqual({ type: 'success' });
    expect(deps.startNewThread).not.toHaveBeenCalled();
    expect((await store.get('t1'))!.task.scheduledStartV1?.automationId).toBe('auto-1');
    expect(deps.deleteAutomation).toHaveBeenCalledWith('auto-old');
  });

  it('records a failed start on the task and clears the schedule', async () => {
    const { store, deps } = await setup();
    vi.mocked(deps.startNewThread).mockResolvedValueOnce({ ok: false, code: 'SPAWN_FAILED', message: 'boom' });
    expect(await runScheduledTaskStart({ runId: 'run3', automationId: 'auto-1', taskId: 't1' }, deps)).toMatchObject({ type: 'failed', errorCode: 'SPAWN_FAILED' });
    const { task } = (await store.get('t1'))!;
    expect(task).not.toHaveProperty('scheduledStartV1');
    expect(task.log.at(-1)?.text).toContain('boom');
  });

  it('sends a session-assigned task to that session instead of opening a new one', async () => {
    const { store, deps } = await setup({ assignee: { kind: 'session', sessionId: 's-chat', title: 'Navegador' }, permissionMode: 'default' });
    expect(await runScheduledTaskStart({ runId: 'run4', automationId: 'auto-1', taskId: 't1' }, deps)).toEqual({ type: 'success', sessionId: 's-chat' });
    expect(deps.continueThread).toHaveBeenCalledWith('s-chat', expect.stringContaining('Revisar la propuesta'), 'run4', 'default');
    expect(deps.startNewThread).not.toHaveBeenCalled();
    expect((await store.get('t1'))!.task).toMatchObject({ status: 'in_progress', threads: ['s-chat'] });
  });
});

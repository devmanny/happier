import { describe, expect, it, vi } from 'vitest';

import { createInMemoryAccountKv } from '@/api/kv/inMemoryAccountKv.testkit';
import { AgentTaskStore } from '@/session/agentTasks/agentTaskStore';

import { runTaskDueCheck } from './taskDueNotifier';

const material = { type: 'dataKey', machineKey: new Uint8Array(32).fill(9) } as const;
const HOUR = 3_600_000;

function setup() {
  const kv = createInMemoryAccountKv();
  const clock = { now: 100 * HOUR };
  let ids = 0;
  const store = new AgentTaskStore({ transport: kv.transport, material, now: () => clock.now, newId: () => `t${++ids}` });
  const push = { sendToAllDevicesAsync: vi.fn(async () => {}) };
  return { kv, clock, store, push };
}

describe('runTaskDueCheck', () => {
  it('tells the user once when their task is due soon and once when it is overdue', async () => {
    const { store, push, clock } = setup();
    await store.create({ title: 'Comprar el cable', assignee: { kind: 'user' }, status: 'todo', threads: [], dueAt: clock.now + 2 * HOUR });
    await store.create({ title: 'De Mateo', assignee: { kind: 'agent', agentId: 'a' }, status: 'todo', threads: [], dueAt: clock.now + HOUR });

    await runTaskDueCheck({ store, push, pushEnabled: () => true, now: () => clock.now });
    await runTaskDueCheck({ store, push, pushEnabled: () => true, now: () => clock.now });
    expect(push.sendToAllDevicesAsync).toHaveBeenCalledTimes(1);
    expect(push.sendToAllDevicesAsync).toHaveBeenLastCalledWith('Task due soon', expect.stringContaining('Comprar el cable'), { type: 'task_due', taskId: 't1' });

    clock.now += 3 * HOUR;
    await runTaskDueCheck({ store, push, pushEnabled: () => true, now: () => clock.now });
    await runTaskDueCheck({ store, push, pushEnabled: () => true, now: () => clock.now });
    expect(push.sendToAllDevicesAsync).toHaveBeenCalledTimes(2);
    expect(push.sendToAllDevicesAsync).toHaveBeenLastCalledWith('Task overdue', expect.stringContaining('Comprar el cable'), { type: 'task_due', taskId: 't1' });
  });

  it('sends nothing and keeps the notice pending while push is off', async () => {
    const { store, push, clock } = setup();
    await store.create({ title: 'Cable', assignee: { kind: 'user' }, status: 'todo', threads: [], dueAt: clock.now - HOUR });
    await runTaskDueCheck({ store, push, pushEnabled: () => false, now: () => clock.now });
    expect(push.sendToAllDevicesAsync).not.toHaveBeenCalled();
    await runTaskDueCheck({ store, push, pushEnabled: () => true, now: () => clock.now });
    expect(push.sendToAllDevicesAsync).toHaveBeenCalledTimes(1);
  });
});

import { describe, expect, it } from 'vitest';

import { openAccountScopedBlobCiphertext, parseAgentTaskV1 } from '@happier-dev/protocol';

import { createInMemoryAccountKv } from '@/api/kv/inMemoryAccountKv.testkit';

import { AgentTaskStore } from './agentTaskStore';
import { runAgentTaskTool } from './runAgentTaskTool';

const material = { type: 'dataKey', machineKey: new Uint8Array(32).fill(4) } as const;

function setup() {
  const kv = createInMemoryAccountKv();
  let ids = 0;
  const store = new AgentTaskStore({ transport: kv.transport, material, now: () => 1_000, newId: () => `t${++ids}` });
  const read = (id: string) => {
    const value = kv.rows.get(`task/${id}`)?.value;
    return value ? parseAgentTaskV1(openAccountScopedBlobCiphertext({ kind: 'agent_task', material, ciphertext: value })?.value) : null;
  };
  return { kv, store, read };
}

const mateo = { agent: { id: 'a-mateo', name: 'Mateo', emoji: '🤖' }, sessionId: 's1' };

describe('runAgentTaskTool', () => {
  it('lets an agent leave the user a task with a due date and a link to where it came from', async () => {
    const { store, read } = setup();
    const result = await runAgentTaskTool({ store, caller: mateo, operation: 'create', input: {
      title: 'Comprar el cable USB-C', assignee: 'user', dueAt: '2026-11-10T18:00:00-06:00',
      sourceKind: 'chat', sourceLabel: 'WhatsApp · Wendoline', sourceUrl: 'https://wa.me/msg/1',
    } });
    expect(result).toMatchObject({ ok: true, taskId: 't1' });
    expect(read('t1')).toMatchObject({
      title: 'Comprar el cable USB-C', assignee: { kind: 'user' }, status: 'todo',
      dueAt: Date.parse('2026-11-10T18:00:00-06:00'),
      source: { kind: 'chat', label: 'WhatsApp · Wendoline', url: 'https://wa.me/msg/1', sessionId: 's1' },
      createdBy: { kind: 'agent', agentId: 'a-mateo', sessionId: 's1' }, threads: [],
    });
  });

  it('links the creating session as a thread only when it works the task itself', async () => {
    const { store, read } = setup();
    const agenda = { agent: null, sessionId: 's9' };
    await runAgentTaskTool({ store, caller: mateo, operation: 'create', input: { title: 'Login' } });
    await runAgentTaskTool({ store, caller: mateo, operation: 'create', input: { title: 'Revisar', assignee: 'a-mateo' } });
    await runAgentTaskTool({ store, caller: mateo, operation: 'create', input: { title: 'Pruebas', assignee: 'a-leo' } });
    await runAgentTaskTool({ store, caller: agenda, operation: 'create', input: { title: 'Dentista', assignee: 'user' } });
    await runAgentTaskTool({ store, caller: agenda, operation: 'create', input: { title: 'Resumen', assignee: 'me' } });
    expect(['t1', 't2', 't3', 't4', 't5'].map((id) => read(id)?.threads)).toEqual([['s1'], ['s1'], [], [], ['s9']]);
    // The session it came from stays linked as its origin, not as a session that worked it.
    expect(read('t3')?.source).toEqual({ kind: 'session', sessionId: 's1' });
    expect(read('t4')?.source).toEqual({ kind: 'session', sessionId: 's9' });
  });

  it('links an updating session only when it works the task', async () => {
    const { store, read } = setup();
    const agenda = { agent: null, sessionId: 's9' };
    await runAgentTaskTool({ store, caller: agenda, operation: 'create', input: { title: 'Dentista', assignee: 'user' } });
    await runAgentTaskTool({ store, caller: agenda, operation: 'update', input: { taskId: 't1', status: 'blocked', comment: 'Falta la dirección' } });
    await runAgentTaskTool({ store, caller: mateo, operation: 'update', input: { taskId: 't1', comment: 'Le escribí al consultorio' } });
    expect(read('t1')).toMatchObject({ status: 'blocked', threads: [] });
    // Taking it over ("me") is working it.
    await runAgentTaskTool({ store, caller: mateo, operation: 'update', input: { taskId: 't1', assignee: 'me', status: 'in_progress' } });
    expect(read('t1')?.threads).toEqual(['s1']);
  });

  it('assigns "me" to the calling agent and refuses it for a session without one', async () => {
    const { store, read } = setup();
    await runAgentTaskTool({ store, caller: mateo, operation: 'create', input: { title: 'Notas', assignee: 'me' } });
    expect(read('t1')?.assignee).toEqual({ kind: 'agent', agentId: 'a-mateo', name: 'Mateo', emoji: '🤖' });
    // A session without an agent: "me" is the session itself.
    await runAgentTaskTool({ store, caller: { agent: null, sessionId: 's9' }, operation: 'create', input: { title: 'x', assignee: 'me' } });
    expect(read('t2')?.assignee).toEqual({ kind: 'session', sessionId: 's9' });
  });

  it('updates status with a comment, links the thread and rejects a bad date', async () => {
    const { store, read } = setup();
    await runAgentTaskTool({ store, caller: mateo, operation: 'create', input: { title: 'Login', assignee: 'me' } });
    const updated = await runAgentTaskTool({ store, caller: { ...mateo, sessionId: 's2' }, operation: 'update', input: {
      taskId: 't1', status: 'in_review', comment: 'Listo para revisar',
    } });
    expect(updated).toMatchObject({ ok: true, status: 'in_review' });
    expect(read('t1')).toMatchObject({ status: 'in_review', threads: ['s1', 's2'] });
    expect(read('t1')?.log.at(-1)).toMatchObject({ text: 'Listo para revisar', status: 'in_review', by: { kind: 'agent', agentId: 'a-mateo', sessionId: 's2' } });
    expect(await runAgentTaskTool({ store, caller: mateo, operation: 'update', input: { taskId: 't1', dueAt: 'mañana' } }))
      .toMatchObject({ ok: false, error: expect.stringContaining('dueAt') });
    expect(await runAgentTaskTool({ store, caller: mateo, operation: 'update', input: { taskId: 'missing', status: 'done' } }))
      .toMatchObject({ ok: false });
  });

  it('keeps a repeating task open: an agent\'s "done" becomes its occurrence\'s result, or is refused', async () => {
    const { store, read } = setup();
    const recurrence = { v: 1 as const, timezone: 'UTC', continuity: 'new_thread' as const, paused: false, rules: [{ id: 'r1', kind: 'weekly' as const, weekdays: [1], time: '09:00' }] };
    await store.create({ title: 'Revisión diaria', assignee: { kind: 'agent', agentId: 'a-mateo' }, status: 'in_progress', threads: ['s1'], recurrence,
      occurrences: [{ id: 'run1', startedAt: 1, sessionId: 's1', status: 'running' }] });

    const done = await runAgentTaskTool({ store, caller: mateo, operation: 'update', input: { taskId: 't1', status: 'done', comment: 'Sin errores hoy' } });
    expect(done).toMatchObject({ ok: true, status: 'in_progress', occurrence: { id: 'run1', status: 'completed' } });
    expect(done.message).toContain('repeats');
    expect(read('t1')).toMatchObject({ status: 'in_progress' });
    expect(read('t1')?.occurrences?.[0]).toMatchObject({ status: 'completed', note: 'Sin errores hoy' });
    expect(read('t1')?.log.at(-1)).toMatchObject({ text: 'Sin errores hoy' });

    // No occurrence of its own running: refused, task untouched.
    const refused = await runAgentTaskTool({ store, caller: { ...mateo, sessionId: 's9' }, operation: 'update', input: { taskId: 't1', status: 'done' } });
    expect(refused).toMatchObject({ ok: false, error: expect.stringContaining('only the user') });
    expect(read('t1')?.status).toBe('in_progress');
  });

  it('builds the calling agent\'s board from its open tasks', async () => {
    const { store } = setup();
    await runAgentTaskTool({ store, caller: mateo, operation: 'create', input: { title: 'Login', assignee: 'me' } });
    await runAgentTaskTool({ store, caller: mateo, operation: 'create', input: { title: 'Cable', assignee: 'user' } });
    const board = await store.boardFor({ agentId: 'a-mateo', sessionId: 's1' });
    expect(board).toContain('t1 · Login · To do');
    expect(board).not.toContain('Cable');
  });
});

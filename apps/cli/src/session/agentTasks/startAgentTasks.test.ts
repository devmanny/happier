import { EventEmitter } from 'node:events';

import { afterEach, describe, expect, it } from 'vitest';

import { createInMemoryAccountKv } from '@/api/kv/inMemoryAccountKv.testkit';

import { resetAgentTasksForTests, startAgentTasks } from './startAgentTasks';

const credentials = { token: 't', encryption: { type: 'dataKey' as const, publicKey: new Uint8Array(32), machineKey: new Uint8Array(32).fill(2) } };
const env = { HAPPIER_AGENT_IDENTITY_JSON: JSON.stringify({ v: 1, id: 'a1', name: 'Mateo' }) };

afterEach(() => resetAgentTasksForTests());

describe('startAgentTasks', () => {
  it('completes the recurring occurrence this thread was working when its turn ends', async () => {
    const kv = createInMemoryAccountKv();
    const session = Object.assign(new EventEmitter(), { sessionId: 's1' });
    const tasks = startAgentTasks(session, credentials, { transport: kv.transport, env })!;
    const task = await tasks.store.create({
      title: 'Revisión diaria', assignee: { kind: 'agent', agentId: 'a1' }, status: 'in_progress', threads: ['s1'],
      occurrences: [{ id: 'run1', startedAt: 1, sessionId: 's1', status: 'running' }, { id: 'run0', startedAt: 0, sessionId: 's0', status: 'running' }],
    });

    session.emit('local-presence', { thinking: true });
    session.emit('local-presence', { thinking: false });
    await tasks.settled();

    const occurrences = (await tasks.store.get(task.id))!.task.occurrences!;
    expect(occurrences.map((o) => [o.id, o.status])).toEqual([['run1', 'completed'], ['run0', 'running']]);
    expect(occurrences[0]!.finishedAt).toEqual(expect.any(Number));
  });

  it('also completes it in a session without an agent', async () => {
    const kv = createInMemoryAccountKv();
    const session = Object.assign(new EventEmitter(), { sessionId: 's-plain' });
    const tasks = startAgentTasks(session, credentials, { transport: kv.transport, env: {} })!;
    const task = await tasks.store.create({
      title: 'Revisión', assignee: { kind: 'session', sessionId: 's-plain' }, status: 'in_progress', threads: ['s-plain'],
      occurrences: [{ id: 'run1', startedAt: 1, sessionId: 's-plain', status: 'running' }],
    });
    session.emit('local-presence', { thinking: true });
    session.emit('local-presence', { thinking: false });
    await tasks.settled();
    expect((await tasks.store.get(task.id))!.task.occurrences?.[0]?.status).toBe('completed');
  });
});

import { describe, expect, it } from 'vitest';

import { openAccountScopedBlobCiphertext, sealAccountScopedBlobCiphertext } from '../crypto/accountScopedCipher.js';
import {
  agentTaskKvKey,
  applyAgentTaskUpdate,
  buildAgentTaskBoard,
  isAgentTaskOpen,
  parseAgentTaskV1,
  taskDueNotices,
  type AgentTaskV1,
} from './agentTask.js';

const HOUR = 3_600_000;

function task(overrides: Partial<AgentTaskV1> = {}): AgentTaskV1 {
  return {
    v: 1,
    id: 't1',
    title: 'Revisar TestFlight',
    assignee: { kind: 'agent', agentId: 'a-mateo', name: 'Mateo' },
    status: 'todo',
    threads: [],
    log: [],
    createdAt: 0,
    updatedAt: 0,
    ...overrides,
  };
}

describe('agent tasks', () => {
  it('keeps the key opaque and seals under its own kind', () => {
    expect(agentTaskKvKey('t1')).toBe('task/t1');
    const material = { type: 'dataKey', machineKey: new Uint8Array(32).fill(1) } as const;
    const ciphertext = sealAccountScopedBlobCiphertext({ kind: 'agent_task', material, payload: task(), randomBytes: (n) => new Uint8Array(n) });
    expect(parseAgentTaskV1(openAccountScopedBlobCiphertext({ kind: 'agent_task', material, ciphertext })?.value)).toEqual(task());
    expect(openAccountScopedBlobCiphertext({ kind: 'agent_memory', material, ciphertext })).toBeNull();
  });

  it('rejects a task without a title or with an unknown status', () => {
    expect(parseAgentTaskV1({ ...task(), title: ' ' })).toBeNull();
    expect(parseAgentTaskV1({ ...task(), status: 'later' })).toBeNull();
  });

  it('applies an update: status, fields, a comment in the log and the thread that worked on it', () => {
    const updated = applyAgentTaskUpdate(task(), {
      status: 'in_progress', dueAt: 5 * HOUR, comment: 'Empecé', by: { kind: 'agent', agentId: 'a-mateo', sessionId: 's1' }, threadSessionId: 's1',
    }, 10);
    expect(updated).toMatchObject({ status: 'in_progress', dueAt: 5 * HOUR, threads: ['s1'], updatedAt: 10 });
    expect(updated.log).toEqual([{ at: 10, by: { kind: 'agent', agentId: 'a-mateo', sessionId: 's1' }, text: 'Empecé', status: 'in_progress' }]);
    // The same thread is linked once; clearing a date uses null.
    const cleared = applyAgentTaskUpdate(updated, { threadSessionId: 's1', dueAt: null }, 11);
    expect(cleared.threads).toEqual(['s1']);
    expect(cleared).not.toHaveProperty('dueAt');
  });

  it('builds the agent board from its open tasks, overdue first, in a few lines', () => {
    const now = 100 * HOUR;
    const board = buildAgentTaskBoard({
      agentId: 'a-mateo',
      now,
      tasks: [
        task({ id: 't-done', status: 'done' }),
        task({ id: 't-late', title: 'Login', status: 'in_progress', dueAt: now - HOUR, directory: '~/app' }),
        task({ id: 't-next', title: 'Notas', status: 'todo', dueAt: now + 30 * HOUR }),
        task({ id: 't-other', assignee: { kind: 'user' } }),
      ],
    });
    expect(board.split('\n')).toEqual([
      '- t-late · Login · In progress · overdue by 1 h · ~/app',
      '- t-next · Notas · To do · due in 30 h',
    ]);
    expect(isAgentTaskOpen(task({ status: 'in_review' }))).toBe(true);
  });

  it('notices the user\'s tasks once when due soon and once when overdue', () => {
    const now = 100 * HOUR;
    const mine = task({ id: 'm1', assignee: { kind: 'user' }, dueAt: now + 2 * HOUR });
    expect(taskDueNotices({ tasks: [mine], now })).toEqual([{ taskId: 'm1', kind: 'due_soon' }]);
    expect(taskDueNotices({ tasks: [{ ...mine, notifiedV1: { dueSoonAt: now - 1 } }], now })).toEqual([]);
    const late = { ...mine, dueAt: now - 1, notifiedV1: { dueSoonAt: now - HOUR } };
    expect(taskDueNotices({ tasks: [late], now })).toEqual([{ taskId: 'm1', kind: 'overdue' }]);
    expect(taskDueNotices({ tasks: [{ ...late, status: 'done' as const }], now })).toEqual([]);
    expect(taskDueNotices({ tasks: [task({ dueAt: now - 1 })], now })).toEqual([]);
  });
});

import { describe, expect, it } from 'vitest';

import { agentTaskKvKey, openAccountScopedBlobCiphertext, sealAccountScopedBlobCiphertext } from '@happier-dev/protocol';

import { createInMemoryAccountKv } from '@/api/kv/inMemoryAccountKv.testkit';

import { AgentTaskStore } from './agentTaskStore';

const material = { type: 'dataKey', machineKey: new Uint8Array(32).fill(5) } as const;

describe('AgentTaskStore', () => {
  it('rewrites a task without dropping fields a newer build added', async () => {
    const kv = createInMemoryAccountKv();
    const newer = {
      v: 1, id: 't1', title: 'Repaso', assignee: { kind: 'user' }, status: 'todo', threads: [], log: [], createdAt: 0, updatedAt: 0,
      futureField: { keep: true },
    };
    await kv.transport.mutate([{ key: agentTaskKvKey('t1'), version: -1,
      value: sealAccountScopedBlobCiphertext({ kind: 'agent_task', material, payload: newer, randomBytes: (n) => new Uint8Array(n) }) }]);
    const store = new AgentTaskStore({ transport: kv.transport, material, now: () => 5 });
    await store.update('t1', (task, at) => ({ ...task, status: 'in_progress', updatedAt: at }));

    const [row] = await kv.transport.list(agentTaskKvKey('t1'));
    const stored = openAccountScopedBlobCiphertext({ kind: 'agent_task', material, ciphertext: row!.value })?.value;
    expect(stored).toMatchObject({ status: 'in_progress', futureField: { keep: true } });
  });
});

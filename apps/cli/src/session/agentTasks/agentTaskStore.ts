import { randomBytes as nodeRandomBytes, randomUUID } from 'node:crypto';

import {
  AGENT_TASK_KV_PREFIX,
  agentTaskKvKey,
  applyAgentTaskUpdate,
  buildAgentTaskBoard,
  openAccountScopedBlobCiphertext,
  parseAgentTaskV1,
  sealAccountScopedBlobCiphertext,
  type AccountScopedCryptoMaterial,
  type AgentTaskUpdate,
  type AgentTaskV1,
} from '@happier-dev/protocol';

import { ACCOUNT_KV_LIST_MAX_ROWS, type AccountKvTransport } from '@/api/kv/accountKvHttpTransport';

export type AgentTaskListing = Readonly<{ tasks: AgentTaskV1[]; complete: boolean }>;

/**
 * The account's tasks in the UserKVStore (`task/<uuid>`, kind `agent_task`). Any thread or the app
 * may edit a task, so every write re-reads it and re-applies the change on a version conflict.
 */
/** A task's declared fields (the schema is passthrough, so its type also admits unknown keys). */
type KnownTaskFields = { [K in keyof AgentTaskV1 as string extends K ? never : K]: AgentTaskV1[K] };

export class AgentTaskStore {
  constructor(private readonly deps: Readonly<{
    transport: AccountKvTransport;
    material: AccountScopedCryptoMaterial;
    now?: () => number;
    newId?: () => string;
    randomBytes?: (length: number) => Uint8Array;
  }>) {}

  /** Every task. The route has no cursor, so `complete` is false when the listing came back full. */
  async list(): Promise<AgentTaskListing> {
    const rows = await this.deps.transport.list(AGENT_TASK_KV_PREFIX);
    const tasks: AgentTaskV1[] = [];
    for (const row of rows) {
      const task = this.open(row.value);
      if (task) tasks.push(task);
    }
    return { tasks, complete: rows.length < ACCOUNT_KV_LIST_MAX_ROWS };
  }

  async get(taskId: string): Promise<Readonly<{ task: AgentTaskV1; version: number }> | null> {
    const key = agentTaskKvKey(taskId);
    const row = (await this.deps.transport.list(key)).find((entry) => entry.key === key);
    const task = row ? this.open(row.value) : null;
    return row && task ? { task, version: row.version } : null;
  }

  async create(fields: Omit<KnownTaskFields, 'v' | 'id' | 'createdAt' | 'updatedAt' | 'log'>): Promise<AgentTaskV1> {
    const now = this.now();
    const task: AgentTaskV1 = { ...fields, v: 1, id: this.deps.newId?.() ?? randomUUID(), log: [], createdAt: now, updatedAt: now };
    const result = await this.deps.transport.mutate([{ key: agentTaskKvKey(task.id), value: this.seal(task), version: -1 }]);
    if (!result.ok) throw new Error('task id collided');
    return task;
  }

  /** Applies `change` to the current task; null when the task doesn't exist. */
  async update(taskId: string, change: (task: AgentTaskV1, now: number) => AgentTaskV1): Promise<AgentTaskV1 | null> {
    const key = agentTaskKvKey(taskId);
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const current = await this.get(taskId);
      if (!current) return null;
      const next = change(current.task, this.now());
      const result = await this.deps.transport.mutate([{ key, value: this.seal(next), version: current.version }]);
      if (result.ok) return next;
    }
    throw new Error('task kept changing while updating it');
  }

  async applyUpdate(taskId: string, update: AgentTaskUpdate): Promise<AgentTaskV1 | null> {
    return await this.update(taskId, (task, now) => applyAgentTaskUpdate(task, update, now));
  }

  /** At the end of a turn in `sessionId`, the recurring occurrences that thread was working are completed. */
  async completeOccurrencesInThread(sessionId: string): Promise<void> {
    const { tasks } = await this.list();
    for (const task of tasks) {
      if (!task.occurrences?.some((entry) => entry.status === 'running' && entry.sessionId === sessionId)) continue;
      await this.update(task.id, (latest, at) => ({
        ...latest,
        occurrences: (latest.occurrences ?? []).map((entry) => (entry.status === 'running' && entry.sessionId === sessionId
          ? { ...entry, status: 'completed' as const, finishedAt: at }
          : entry)),
        updatedAt: at,
      }));
    }
  }

  /** A thread's open tasks in a few lines (its board): its agent's and its session's; empty when none. */
  async boardFor(owner: Readonly<{ agentId?: string | null; sessionId?: string | null }>): Promise<string> {
    const { tasks, complete } = await this.list();
    const board = buildAgentTaskBoard({ ...owner, tasks, now: this.now() });
    return board && !complete ? `${board}\n- (more tasks than one listing holds; some may be missing)` : board;
  }

  private open(ciphertext: string): AgentTaskV1 | null {
    const opened = openAccountScopedBlobCiphertext({ kind: 'agent_task', material: this.deps.material, ciphertext });
    return opened ? parseAgentTaskV1(opened.value) : null;
  }

  private seal(task: AgentTaskV1): string {
    return sealAccountScopedBlobCiphertext({
      kind: 'agent_task',
      material: this.deps.material,
      payload: task,
      randomBytes: this.deps.randomBytes ?? ((length) => new Uint8Array(nodeRandomBytes(length))),
    });
  }

  private now(): number {
    return this.deps.now?.() ?? Date.now();
  }
}

import { randomBytes as nodeRandomBytes } from 'node:crypto';

import {
  AGENT_PRESENCE_KV_PREFIX,
  agentPresenceKvKey,
  describePresenceConflict,
  findPresenceConflicts,
  isAgentPresenceLive,
  openAccountScopedBlobCiphertext,
  parseAgentPresenceV1,
  sealAccountScopedBlobCiphertext,
  type AccountScopedCryptoMaterial,
  type AgentPresenceV1,
} from '@happier-dev/protocol';

/** The relay's UserKVStore (`/v1/kv`), reduced to what presence needs. */
export type PresenceKvTransport = Readonly<{
  list: (prefix: string) => Promise<ReadonlyArray<Readonly<{ key: string; value: string; version: number }>>>;
  mutate: (mutations: ReadonlyArray<Readonly<{ key: string; value: string | null; version: number }>>) => Promise<
    | Readonly<{ ok: true; results: ReadonlyArray<Readonly<{ key: string; version: number }>> }>
    | Readonly<{ ok: false; current: ReadonlyArray<Readonly<{ key: string; version: number }>> }>
  >;
}>;

/** What this thread is, read fresh on every write (title and folder can change mid-session). */
export type PresenceSelfDescription = Pick<AgentPresenceV1, 'agent' | 'providerId' | 'machineId' | 'host' | 'directory' | 'task'>;

export type WhoIsHereReport = Readonly<{
  self: AgentPresenceV1 | null;
  /** Other live threads, same folder first. */
  others: AgentPresenceV1[];
  /** One line per file/resource this thread holds that another live thread also holds. */
  conflicts: string[];
}>;

/** Reads of the other threads are shared for this long, so a burst of edits costs one list. */
const OTHERS_CACHE_MS = 5_000;

/**
 * This thread's "who is where" record. Only this thread writes `presence/<sessionId>`.
 * Advisory: callers get warnings, nothing is ever blocked.
 */
export class SessionPresence {
  private readonly files = new Map<string, number>();
  private readonly resources = new Map<string, number>();
  private working = false;
  private published = false;
  private version = -1;
  private writes: Promise<void> = Promise.resolve();
  private othersCache: { at: number; records: AgentPresenceV1[] } | null = null;

  constructor(private readonly deps: Readonly<{
    sessionId: string;
    transport: PresenceKvTransport;
    material: AccountScopedCryptoMaterial;
    describeSelf: () => PresenceSelfDescription;
    now?: () => number;
    randomBytes?: (length: number) => Uint8Array;
  }>) {}

  get sessionId(): string {
    return this.deps.sessionId;
  }

  get isPublished(): boolean {
    return this.published;
  }

  /** A turn started (publish) or ended (release everything and remove the record). */
  async setWorking(working: boolean): Promise<void> {
    if (working === this.working) return;
    this.working = working;
    if (!working) {
      this.files.clear();
      this.resources.clear();
    }
    await this.write();
  }

  /** Resolves once every write queued so far has finished. */
  flush(): Promise<void> {
    return this.writes;
  }

  /** Refresh the record's "last signal" while a turn keeps running. */
  async heartbeat(): Promise<void> {
    if (this.published) await this.write();
  }

  /** Records the file as ours and returns a warning when another live thread holds it. */
  async beforeFileEdit(path: string): Promise<string | null> {
    const others = await this.readOthers();
    const now = this.now();
    if (!this.files.has(path)) this.files.set(path, now);
    await this.write();
    const conflicts = findPresenceConflicts({ selfSessionId: this.deps.sessionId, records: others, now, filePath: path });
    return conflicts.length > 0 ? conflicts.map((conflict) => describePresenceConflict(conflict, now)).join('\n') : null;
  }

  /** Files edits observed after the fact (providers that don't ask first). */
  async noteFilesEdited(paths: readonly string[]): Promise<void> {
    const now = this.now();
    let changed = false;
    for (const path of paths) {
      if (!this.files.has(path)) {
        this.files.set(path, now);
        changed = true;
      }
    }
    if (changed) await this.write();
  }

  /** Optionally declares shared resources in use, then reports every other live thread. */
  async whoIsHere(params: Readonly<{ resources?: readonly string[]; task?: string }> = {}): Promise<WhoIsHereReport> {
    const now = this.now();
    if (params.resources) {
      for (const name of params.resources.map((value) => value.trim()).filter(Boolean)) {
        if (!this.resources.has(name)) this.resources.set(name, now);
      }
      await this.write();
    }
    const others = await this.readOthers({ fresh: true });
    const self = this.buildRecord();
    const conflicts = [
      ...[...this.files.keys()].flatMap((filePath) =>
        findPresenceConflicts({ selfSessionId: this.deps.sessionId, records: others, now, filePath })),
      ...[...this.resources.keys()].flatMap((resource) =>
        findPresenceConflicts({ selfSessionId: this.deps.sessionId, records: others, now, resource })),
    ].map((conflict) => describePresenceConflict(conflict, now));
    const directory = self.directory;
    const sorted = [...others].sort((a, b) => Number(b.directory === directory) - Number(a.directory === directory));
    return { self: this.published ? self : null, others: sorted, conflicts };
  }

  private now(): number {
    return this.deps.now?.() ?? Date.now();
  }

  private buildRecord(): AgentPresenceV1 {
    return {
      v: 1,
      sessionId: this.deps.sessionId,
      ...this.deps.describeSelf(),
      files: [...this.files].map(([path, since]) => ({ path, since })),
      resources: [...this.resources].map(([name, since]) => ({ name, since })),
      updatedAt: this.now(),
    };
  }

  private shouldPublish(): boolean {
    return this.working || this.files.size > 0 || this.resources.size > 0;
  }

  /** Writes are serialized; each one writes the latest state. */
  private write(): Promise<void> {
    const next = this.writes.then(() => this.writeLatest());
    this.writes = next.catch(() => undefined);
    return next;
  }

  private async writeLatest(): Promise<void> {
    const publish = this.shouldPublish();
    if (!publish && !this.published) return;
    const key = agentPresenceKvKey(this.deps.sessionId);
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const value = publish
        ? sealAccountScopedBlobCiphertext({
            kind: 'agent_presence',
            material: this.deps.material,
            payload: this.buildRecord(),
            randomBytes: this.deps.randomBytes ?? ((length) => new Uint8Array(nodeRandomBytes(length))),
          })
        : null;
      const result = await this.deps.transport.mutate([{ key, value, version: this.version }]);
      if (result.ok) {
        this.version = result.results.find((entry) => entry.key === key)?.version ?? this.version + 1;
        this.published = publish;
        return;
      }
      // Only this thread writes this key; a mismatch means a previous runner of the same
      // session (or a lost response) moved it. Take the server's version and write again.
      this.version = result.current.find((entry) => entry.key === key)?.version ?? -1;
    }
    throw new Error('presence write kept conflicting');
  }

  private async readOthers(options: Readonly<{ fresh?: boolean }> = {}): Promise<AgentPresenceV1[]> {
    const now = this.now();
    if (!options.fresh && this.othersCache && now - this.othersCache.at < OTHERS_CACHE_MS) {
      return this.othersCache.records;
    }
    const items = await this.deps.transport.list(AGENT_PRESENCE_KV_PREFIX);
    const records: AgentPresenceV1[] = [];
    for (const item of items) {
      if (item.key === agentPresenceKvKey(this.deps.sessionId)) continue;
      const opened = openAccountScopedBlobCiphertext({ kind: 'agent_presence', material: this.deps.material, ciphertext: item.value });
      const record = opened ? parseAgentPresenceV1(opened.value) : null;
      if (record && isAgentPresenceLive(record, now)) records.push(record);
    }
    this.othersCache = { at: now, records };
    return records;
  }
}

function ago(now: number, at: number): string {
  const seconds = Math.max(0, Math.round((now - at) / 1000));
  return seconds < 90 ? `${seconds}s ago` : `${Math.round(seconds / 60)} min ago`;
}

function projectRecord(record: AgentPresenceV1, now: number) {
  return {
    sessionId: record.sessionId,
    agent: record.agent ? `${record.agent.name}${record.agent.emoji ? ` ${record.agent.emoji}` : ''}` : null,
    provider: record.providerId,
    machine: record.host ?? record.machineId,
    directory: record.directory,
    task: record.task,
    files: record.files.map((file) => ({ path: file.path, since: ago(now, file.since) })),
    resources: record.resources.map((resource) => ({ name: resource.name, since: ago(now, resource.since) })),
    lastSignal: ago(now, record.updatedAt),
  };
}

/** What `quien_esta_aqui` returns to the model. */
export function toWhoIsHereResult(report: WhoIsHereReport, now: number = Date.now()) {
  return {
    advisory: 'Warnings, not locks: coordinate with the other thread, wait, or work on something else.',
    you: report.self ? projectRecord(report.self, now) : null,
    others: report.others.map((record) => projectRecord(record, now)),
    conflicts: report.conflicts,
  };
}

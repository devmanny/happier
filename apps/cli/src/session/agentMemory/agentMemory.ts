import { randomBytes as nodeRandomBytes, randomUUID } from 'node:crypto';

import {
  agentJournalKvKey,
  agentMemoryKvPrefix,
  agentNoteKvKey,
  agentNowKvKey,
  buildOtherThreadsSummary,
  openAccountScopedBlobCiphertext,
  parseAgentMemoryRecord,
  sealAccountScopedBlobCiphertext,
  searchAgentMemory,
  type AccountScopedCryptoMaterial,
  type AgentMemoryRecord,
  type AgentNowV1,
} from '@happier-dev/protocol';

import type { AccountKvTransport } from '@/api/kv/accountKvHttpTransport';

export type AgentMemorySelfDescription = Readonly<{ title?: string; directory?: string; host?: string }>;

/** The other threads' summary is reused for this long, so a burst of sends/steers costs one read. */
const TURN_CONTEXT_CACHE_MS = 30_000;

/**
 * One agent thread's view of the agent's shared memory (`packages/protocol/src/agentProfiles/agentMemory.ts`).
 * It owns this thread's `now` record; journal entries and notes are shared by every thread.
 *
 * Reads list one prefix of the UserKVStore, which returns at most 1000 rows; past that the
 * oldest journal entries of a single listing are not seen (the journal is read per day).
 */
export class AgentMemory {
  private nowText: string | null = null;
  private nowVersion = -1;
  private turnContext: { at: number; block: string | null } | null = null;

  constructor(private readonly deps: Readonly<{
    agentId: string;
    sessionId: string;
    transport: AccountKvTransport;
    material: AccountScopedCryptoMaterial;
    describeSelf: () => AgentMemorySelfDescription;
    now?: () => number;
    newId?: () => string;
    /** The local calendar day, `YYYY-MM-DD`. */
    today?: () => string;
    randomBytes?: (length: number) => Uint8Array;
  }>) {}

  get agentId(): string {
    return this.deps.agentId;
  }

  get sessionId(): string {
    return this.deps.sessionId;
  }

  /** A turn started: refresh this thread's `now`, keeping what the agent last said it is doing. */
  async touchNow(): Promise<void> {
    await this.writeNow(this.nowText);
  }

  async setNow(text: string): Promise<AgentNowV1> {
    this.nowText = text.trim() || null;
    return await this.writeNow(this.nowText);
  }

  async appendJournal(text: string): Promise<Readonly<{ key: string }>> {
    const id = this.newId();
    const key = agentJournalKvKey(this.deps.agentId, this.today(), id);
    const result = await this.deps.transport.mutate([{
      key,
      value: this.seal({ v: 1, id, sessionId: this.deps.sessionId, text: text.trim(), at: this.now() }),
      version: -1,
    }]);
    if (!result.ok) throw new Error('journal entry id collided');
    return { key };
  }

  /** Creates a note (no `noteId`) or replaces one, re-reading its version when another writer moved it. */
  async writeNote(params: Readonly<{ noteId?: string; title: string; markdown: string }>): Promise<Readonly<{ id: string; key: string }>> {
    const id = params.noteId ?? this.newId();
    const key = agentNoteKvKey(this.deps.agentId, id);
    let version = params.noteId ? await this.currentVersion(key) : -1;
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const result = await this.deps.transport.mutate([{
        key,
        value: this.seal({ v: 1, id, title: params.title.trim(), markdown: params.markdown, updatedAt: this.now() }),
        version,
      }]);
      if (result.ok) return { id, key };
      version = result.current.find((entry) => entry.key === key)?.version ?? -1;
    }
    throw new Error('note kept changing while writing it');
  }

  async read(params: Readonly<{ kind: 'now' | 'journal' | 'notes' | 'note'; day?: string; noteId?: string; limit?: number }>): Promise<AgentMemoryRecord[]> {
    const prefix = params.kind === 'note' && params.noteId
      ? agentNoteKvKey(this.deps.agentId, params.noteId)
      : agentMemoryKvPrefix(this.deps.agentId, params.kind === 'notes' || params.kind === 'note' ? 'note' : params.kind,
        params.kind === 'journal' ? (params.day ?? this.today()) : undefined);
    const records = await this.list(prefix);
    const time = (record: AgentMemoryRecord) => (record.kind === 'journal' ? record.value.at : record.value.updatedAt);
    const sorted = records.sort((a, b) => time(b) - time(a));
    return params.limit ? sorted.slice(0, params.limit) : sorted;
  }

  async search(query: string, limit = 20): Promise<AgentMemoryRecord[]> {
    const records = await this.list(`agent/${this.deps.agentId}/`);
    return searchAgentMemory(records, query).slice(0, limit);
  }

  /** Every thread's `now`, newest first (this one included). */
  async threads(): Promise<AgentNowV1[]> {
    const records = await this.list(agentMemoryKvPrefix(this.deps.agentId, 'now'));
    return records
      .flatMap((record) => (record.kind === 'now' ? [record.value] : []))
      .sort((a, b) => b.updatedAt - a.updatedAt);
  }

  invalidateTurnContext(): void {
    this.turnContext = null;
  }

  /** A few lines for the start of a turn about the agent's other threads; null when there are none. */
  async turnContextBlock(): Promise<string | null> {
    const now = this.now();
    if (this.turnContext && now - this.turnContext.at < TURN_CONTEXT_CACHE_MS) return this.turnContext.block;
    const summary = buildOtherThreadsSummary({ selfSessionId: this.deps.sessionId, nows: await this.threads(), now });
    const block = summary
      ? [
          '[Happier · your other threads right now. You are one agent across them: check memoria_buscar or mis_hilos before answering about their work.]',
          summary,
        ].join('\n')
      : null;
    this.turnContext = { at: now, block };
    return block;
  }

  private async writeNow(text: string | null): Promise<AgentNowV1> {
    const self = this.deps.describeSelf();
    const key = agentNowKvKey(this.deps.agentId, this.deps.sessionId);
    const record: AgentNowV1 = {
      v: 1,
      sessionId: this.deps.sessionId,
      text: text ?? self.title ?? 'Working',
      ...(self.title ? { title: self.title } : {}),
      ...(self.directory ? { directory: self.directory } : {}),
      ...(self.host ? { host: self.host } : {}),
      updatedAt: this.now(),
    };
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const result = await this.deps.transport.mutate([{ key, value: this.seal(record), version: this.nowVersion }]);
      if (result.ok) {
        this.nowVersion = result.results.find((entry) => entry.key === key)?.version ?? this.nowVersion + 1;
        return record;
      }
      // Only this thread writes its `now`; a mismatch is an earlier runner of the same session.
      this.nowVersion = result.current.find((entry) => entry.key === key)?.version ?? -1;
    }
    throw new Error('now record kept conflicting');
  }

  private async currentVersion(key: string): Promise<number> {
    const rows = await this.deps.transport.list(key);
    return rows.find((row) => row.key === key)?.version ?? -1;
  }

  private async list(prefix: string): Promise<AgentMemoryRecord[]> {
    const rows = await this.deps.transport.list(prefix);
    const records: AgentMemoryRecord[] = [];
    for (const row of rows) {
      const opened = openAccountScopedBlobCiphertext({ kind: 'agent_memory', material: this.deps.material, ciphertext: row.value });
      const record = opened ? parseAgentMemoryRecord(row.key, opened.value) : null;
      if (record) records.push(record);
    }
    return records;
  }

  private seal(payload: unknown): string {
    return sealAccountScopedBlobCiphertext({
      kind: 'agent_memory',
      material: this.deps.material,
      payload,
      randomBytes: this.deps.randomBytes ?? ((length) => new Uint8Array(nodeRandomBytes(length))),
    });
  }

  private now(): number {
    return this.deps.now?.() ?? Date.now();
  }

  private newId(): string {
    return this.deps.newId?.() ?? randomUUID();
  }

  private today(): string {
    if (this.deps.today) return this.deps.today();
    const date = new Date(this.now());
    const pad = (value: number) => String(value).padStart(2, '0');
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
  }
}

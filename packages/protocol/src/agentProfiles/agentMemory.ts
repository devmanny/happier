import { z } from 'zod';

/**
 * An agent's memory, shared by all its threads (sessions), sealed in the account's UserKVStore
 * (kind `agent_memory`). Keys stay opaque; titles and text live only in the sealed value.
 *
 * - `agent/<agentId>/now/<sessionId>`: what that thread is doing now. Only that thread writes it.
 * - `agent/<agentId>/journal/<YYYY-MM-DD>/<entryId>`: append-only log of facts, decisions and
 *   findings. Each entry is its own key created with version -1, so threads never collide.
 * - `agent/<agentId>/note/<noteId>`: Markdown notes with `[[links]]`, edited by any thread or the user.
 */
export function agentNowKvKey(agentId: string, sessionId: string): string {
  return `agent/${agentId}/now/${sessionId}`;
}

export function agentJournalKvKey(agentId: string, day: string, entryId: string): string {
  return `agent/${agentId}/journal/${day}/${entryId}`;
}

export function agentNoteKvKey(agentId: string, noteId: string): string {
  return `agent/${agentId}/note/${noteId}`;
}

export function agentMemoryKvPrefix(agentId: string, kind: 'now' | 'journal' | 'note', day?: string): string {
  return kind === 'journal' && day ? `agent/${agentId}/journal/${day}/` : `agent/${agentId}/${kind}/`;
}

export type AgentMemoryKvKey =
  | Readonly<{ agentId: string; kind: 'now' | 'note'; id: string }>
  | Readonly<{ agentId: string; kind: 'journal'; day: string; id: string }>;

export function parseAgentMemoryKvKey(key: string): AgentMemoryKvKey | null {
  const parts = key.split('/');
  if (parts[0] !== 'agent' || !parts[1]) return null;
  if ((parts[2] === 'now' || parts[2] === 'note') && parts.length === 4 && parts[3]) {
    return { agentId: parts[1], kind: parts[2], id: parts[3] };
  }
  if (parts[2] === 'journal' && parts.length === 5 && parts[3] && parts[4]) {
    return { agentId: parts[1], kind: 'journal', day: parts[3], id: parts[4] };
  }
  return null;
}

export const AgentNowV1Schema = z.object({
  v: z.literal(1),
  sessionId: z.string().min(1),
  text: z.string(),
  title: z.string().optional(),
  directory: z.string().optional(),
  host: z.string().optional(),
  updatedAt: z.number(),
}).strip();
export type AgentNowV1 = z.infer<typeof AgentNowV1Schema>;

export const AgentJournalEntryV1Schema = z.object({
  v: z.literal(1),
  id: z.string().min(1),
  sessionId: z.string().optional(),
  text: z.string().min(1),
  at: z.number(),
}).strip();
export type AgentJournalEntryV1 = z.infer<typeof AgentJournalEntryV1Schema>;

export const AgentNoteV1Schema = z.object({
  v: z.literal(1),
  id: z.string().min(1),
  title: z.string(),
  markdown: z.string(),
  updatedAt: z.number(),
}).strip();
export type AgentNoteV1 = z.infer<typeof AgentNoteV1Schema>;

export type AgentMemoryRecord =
  | Readonly<{ kind: 'now'; key: string; value: AgentNowV1 }>
  | Readonly<{ kind: 'journal'; key: string; value: AgentJournalEntryV1 }>
  | Readonly<{ kind: 'note'; key: string; value: AgentNoteV1 }>;

/** The record a decrypted value is, by its key; null when it isn't a well-formed memory record. */
export function parseAgentMemoryRecord(key: string, value: unknown): AgentMemoryRecord | null {
  const parsedKey = parseAgentMemoryKvKey(key);
  if (!parsedKey) return null;
  if (parsedKey.kind === 'now') {
    const parsed = AgentNowV1Schema.safeParse(value);
    return parsed.success ? { kind: 'now', key, value: parsed.data } : null;
  }
  if (parsedKey.kind === 'journal') {
    const parsed = AgentJournalEntryV1Schema.safeParse(value);
    return parsed.success ? { kind: 'journal', key, value: parsed.data } : null;
  }
  const parsed = AgentNoteV1Schema.safeParse(value);
  return parsed.success ? { kind: 'note', key, value: parsed.data } : null;
}

export function describeAgo(ms: number): string {
  const minutes = Math.floor(Math.max(0, ms) / 60_000);
  if (minutes < 1) return 'less than a minute ago';
  if (minutes < 120) return `${minutes} min ago`;
  const hours = Math.floor(minutes / 60);
  return hours < 48 ? `${hours} h ago` : `${Math.floor(hours / 24)} days ago`;
}

/** A few lines about the agent's other threads, newest first: what each is doing and how long ago. */
export function buildOtherThreadsSummary(params: Readonly<{
  selfSessionId: string;
  nows: readonly AgentNowV1[];
  now: number;
}>): string {
  return params.nows
    .filter((entry) => entry.sessionId !== params.selfSessionId)
    .sort((a, b) => b.updatedAt - a.updatedAt)
    .map((entry) => {
      const where = [entry.title, [entry.host, entry.directory].filter(Boolean).join(' ')].filter(Boolean).join(' · ');
      return `- ${entry.sessionId}: ${entry.text}${where ? ` — ${where}` : ''} (${describeAgo(params.now - entry.updatedAt)})`;
    })
    .join('\n');
}

function fold(text: string): string {
  return text.normalize('NFD').replace(/\p{Diacritic}/gu, '').toLowerCase();
}

function searchableText(record: AgentMemoryRecord): string {
  if (record.kind === 'note') return `${record.value.title}\n${record.value.markdown}`;
  if (record.kind === 'journal') return record.value.text;
  return [record.value.text, record.value.title, record.value.directory].filter(Boolean).join('\n');
}

/**
 * Records containing every term of `query` (case- and accent-insensitive), newest first. The
 * server can't search sealed values, so this runs where they are decrypted.
 */
export function searchAgentMemory(records: readonly AgentMemoryRecord[], query: string): AgentMemoryRecord[] {
  const terms = fold(query).split(/\s+/).filter(Boolean);
  if (terms.length === 0) return [];
  const time = (record: AgentMemoryRecord) =>
    record.kind === 'journal' ? record.value.at : record.value.updatedAt;
  return records
    .filter((record) => {
      const text = fold(searchableText(record));
      return terms.every((term) => text.includes(term));
    })
    .sort((a, b) => time(b) - time(a));
}

/** `[[Target]]` and `[[Target|label]]` links in a note, as Obsidian reads them. */
export function extractNoteLinks(markdown: string): string[] {
  return [...markdown.matchAll(/\[\[([^\]|]+)(?:\|[^\]]*)?\]\]/g)].map((match) => match[1]!.trim());
}

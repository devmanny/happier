import { describeAgo, type AgentMemoryRecord } from '@happier-dev/protocol';

import { ACCOUNT_KV_LIST_MAX_ROWS } from '@/api/kv/accountKvHttpTransport';

import type { AgentMemory } from './agentMemory';

export type AgentMemoryToolOperation = 'read' | 'search' | 'write' | 'now' | 'threads';

export type ThreadMessage = Readonly<{ role: string; text: string; createdAt: number }>;

const THREAD_MESSAGES_DEFAULT_LIMIT = 10;

function readString(input: Record<string, unknown>, key: string): string | null {
  const value = input[key];
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : null;
}

function readLimit(input: Record<string, unknown>): number | undefined {
  const value = input.limit;
  return typeof value === 'number' && Number.isInteger(value) && value > 0 ? value : undefined;
}

/** The route has no cursor: a full listing is said out loud, never cut silently. */
function completeness(complete: boolean, prefixLabel: string) {
  return complete ? {} : {
    incomplete: true,
    note: `Only the first ${ACCOUNT_KV_LIST_MAX_ROWS} ${prefixLabel} records could be read (the store has no paging yet); results may be missing older entries.`,
  };
}

/** What the model sees for a record: its content, where it lives, and how old it is. */
function project(record: AgentMemoryRecord, now: number) {
  if (record.kind === 'journal') {
    return { kind: 'journal', key: record.key, text: record.value.text, thread: record.value.sessionId ?? null, when: describeAgo(now - record.value.at) };
  }
  if (record.kind === 'note') {
    return { kind: 'note', noteId: record.value.id, title: record.value.title, markdown: record.value.markdown, updated: describeAgo(now - record.value.updatedAt) };
  }
  return { kind: 'now', thread: record.value.sessionId, text: record.value.text, title: record.value.title ?? null, updated: describeAgo(now - record.value.updatedAt) };
}

/** The `memoria_*`, `ahora_actualizar` and `mis_hilos` tools, run in the agent thread's own runner. */
export async function runAgentMemoryTool(params: Readonly<{
  memory: AgentMemory;
  operation: AgentMemoryToolOperation;
  input: Record<string, unknown>;
  readThreadMessages?: (threadSessionId: string, limit: number) => Promise<readonly ThreadMessage[]>;
  now?: number;
}>): Promise<Record<string, unknown>> {
  const { memory, input } = params;
  const now = params.now ?? Date.now();
  switch (params.operation) {
    case 'read': {
      const kind = input.kind;
      if (kind !== 'now' && kind !== 'journal' && kind !== 'notes' && kind !== 'note') {
        return { ok: false, error: 'kind must be now, journal, notes or note' };
      }
      if (kind === 'note' && !readString(input, 'noteId')) return { ok: false, error: 'noteId is required to read one note' };
      const listing = await memory.read({
        kind,
        ...(readString(input, 'day') ? { day: readString(input, 'day')! } : {}),
        ...(readString(input, 'noteId') ? { noteId: readString(input, 'noteId')! } : {}),
        ...(readLimit(input) ? { limit: readLimit(input)! } : {}),
      });
      return { ok: true, records: listing.items.map((record) => project(record, now)), ...completeness(listing.complete, kind) };
    }
    case 'search': {
      const query = readString(input, 'query');
      if (!query) return { ok: false, error: 'query is required' };
      const listing = await memory.search(query, readLimit(input));
      return { ok: true, records: listing.items.map((record) => project(record, now)), ...completeness(listing.complete, 'memory') };
    }
    case 'write': {
      if (input.kind === 'journal') {
        const text = readString(input, 'text');
        if (!text) return { ok: false, error: 'text is required for a journal entry' };
        const { key } = await memory.appendJournal(text);
        memory.invalidateTurnContext();
        return { ok: true, key };
      }
      if (input.kind === 'note') {
        const title = readString(input, 'title');
        if (!title) return { ok: false, error: 'title is required for a note' };
        const markdown = typeof input.markdown === 'string' ? input.markdown : (readString(input, 'text') ?? '');
        const noteId = readString(input, 'noteId');
        const written = await memory.writeNote({ ...(noteId ? { noteId } : {}), title, markdown });
        return { ok: true, noteId: written.id };
      }
      return { ok: false, error: 'kind must be journal or note' };
    }
    case 'now': {
      const text = readString(input, 'text');
      if (!text) return { ok: false, error: 'text is required' };
      const record = await memory.setNow(text);
      return { ok: true, now: record.text };
    }
    case 'threads': {
      const listing = await memory.threads();
      const threads = listing.items;
      const threadSessionId = readString(input, 'threadSessionId');
      if (!threadSessionId) {
        return {
          ok: true,
          threads: threads.map((thread) => ({
            sessionId: thread.sessionId,
            isThisThread: thread.sessionId === memory.sessionId,
            now: thread.text,
            title: thread.title ?? null,
            where: [thread.host, thread.directory].filter(Boolean).join(' ') || null,
            updated: describeAgo(now - thread.updatedAt),
          })),
          hint: 'Pass threadSessionId to read a thread\'s recent messages, or ask it with session_message_send.',
          ...completeness(listing.complete, 'thread'),
        };
      }
      // Only this agent's own threads: a thread is one that wrote a `now` for this agent.
      if (!threads.some((thread) => thread.sessionId === threadSessionId)) {
        return { ok: false, error: `${threadSessionId} is not one of your threads as this agent` };
      }
      if (!params.readThreadMessages) return { ok: false, error: 'reading another thread is not available here' };
      const messages = await params.readThreadMessages(threadSessionId, readLimit(input) ?? THREAD_MESSAGES_DEFAULT_LIMIT);
      return { ok: true, threadSessionId, messages: messages.map((message) => ({ ...message, when: describeAgo(now - message.createdAt) })) };
    }
  }
}

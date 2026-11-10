import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';

import type { InheritedUncertainPendingDelivery } from '@/api/session/sessionClientPort';
import {
  classifyClaudeInheritedPendingDelivery,
  recoverClaudeUnifiedInheritedPendingDeliveries,
} from './inheritedPendingDeliveryRecovery';

// Row shapes as Claude Code 2.x writes them (observed on the 2026-11-10 restart incident).
const iso = (ms: number) => new Date(ms).toISOString();
let uuidSeq = 0;
const nextUuid = () => `00000000-0000-4000-8000-${String(++uuidSeq).padStart(12, '0')}`;
const userPrompt = (text: string, atMs: number, extra: Record<string, unknown> = {}) => ({
  type: 'user', uuid: nextUuid(), parentUuid: nextUuid(), sessionId: 'claude-1', timestamp: iso(atMs), isSidechain: false,
  userType: 'external', promptSource: 'typed', message: { role: 'user', content: text }, ...extra,
});
const nativeQueue = (operation: 'enqueue' | 'remove', text: string, atMs: number) => ({
  type: 'queue-operation', operation, content: text, sessionId: 'claude-1', timestamp: iso(atMs),
});
const queuedCommand = (text: string, atMs: number) => ({
  type: 'attachment', uuid: nextUuid(), parentUuid: nextUuid(), sessionId: 'claude-1', timestamp: iso(atMs), isSidechain: false,
  attachment: { type: 'queued_command', prompt: text, commandMode: 'prompt', origin: { kind: 'human' }, timestamp: iso(atMs) },
});
const assistant = (atMs: number) => ({
  type: 'assistant', uuid: nextUuid(), sessionId: 'claude-1', timestamp: iso(atMs), isSidechain: false,
  message: { role: 'assistant', content: [{ type: 'text', text: 'ok' }] },
});

const CREATED = Date.parse('2026-11-10T16:36:31.459Z');
const RESTART = Date.parse('2026-11-10T16:57:34.000Z');
const PROMPT = 'Acabo de reiniciar la MAC, revisa si llegó todo';

function classify(rows: readonly unknown[], overrides: Partial<Parameters<typeof classifyClaudeInheritedPendingDelivery>[0]> = {}) {
  return classifyClaudeInheritedPendingDelivery({
    promptText: PROMPT,
    createdAtMs: CREATED,
    evidenceBeforeMs: RESTART,
    transcriptRows: rows,
    predecessorConfirmedDead: true,
    competingPromptTexts: [],
    ...overrides,
  });
}

describe('classifyClaudeInheritedPendingDelivery', () => {
  it('is received when the predecessor consumed exactly this prompt once', () => {
    expect(classify([assistant(CREATED - 5_000), userPrompt(PROMPT, CREATED + 60_000)])).toBe('received');
    // A steer consumed from Claude's native queue, pasted-content markers and all.
    expect(classify([
      nativeQueue('enqueue', `<pasted_content id="9b65">\n${PROMPT}\n</pasted_content id="9b65">`, CREATED + 60_000),
      nativeQueue('remove', PROMPT, CREATED + 70_000),
      queuedCommand(`<pasted_content id="9b65">\n${PROMPT}\n</pasted_content id="9b65">`, CREATED + 70_000),
    ])).toBe('received');
  });

  it('recognizes the prompt with the provider-only context Happier appends, and nothing else', () => {
    const board = '[Happier · your open tasks (update them with tarea_actualizar and their id).]\n- t1 Publicar build';
    expect(classify([userPrompt(`${PROMPT}\n\n${board}`, CREATED + 1_000)])).toBe('received');
    expect(classify([userPrompt(`${PROMPT}\n\n<happier_session_reference>\n- session id: s2\n</happier_session_reference>`, CREATED + 1_000)])).toBe('received');
    // A different, longer message that merely starts with the same words is not this prompt.
    expect(classify([userPrompt(`${PROMPT}\n\nY además revisa los logs`, CREATED + 1_000)])).toBe('undetermined');
  });

  it('is not received when the dead predecessor never consumed it, even if its native queue held it', () => {
    // The 2026-11-10 incident: enqueued 79 s after the claim, never removed, then the Mac restarted.
    expect(classify([assistant(CREATED - 1_000), nativeQueue('enqueue', PROMPT, CREATED + 256_000)])).toBe('not_received');
    // Never reached Claude at all.
    expect(classify([assistant(CREATED - 1_000)])).toBe('not_received');
  });

  it('stays undetermined whenever the evidence could be another prompt or the predecessor may still act', () => {
    // Two identical consumptions, or another inherited row with the same text: no exact identity.
    expect(classify([userPrompt(PROMPT, CREATED + 1_000), userPrompt(PROMPT, CREATED + 2_000)])).toBe('undetermined');
    expect(classify([userPrompt(PROMPT, CREATED + 1_000)], { competingPromptTexts: [`  ${PROMPT}\n`] })).toBe('undetermined');
    // Delivered inside a larger prompt (batched or with a replay seed).
    expect(classify([userPrompt(`contexto previo\n\n${PROMPT}`, CREATED + 1_000)])).toBe('undetermined');
    // Claude took it out of its queue but the consumption row is missing.
    expect(classify([nativeQueue('enqueue', PROMPT, CREATED + 1_000), nativeQueue('remove', PROMPT, CREATED + 2_000)])).toBe('undetermined');
    // No proof the predecessor is gone: its terminal may still be holding the prompt.
    expect(classify([nativeQueue('enqueue', PROMPT, CREATED + 1_000)], { predecessorConfirmedDead: false })).toBe('undetermined');
    expect(classify([], { predecessorConfirmedDead: false })).toBe('undetermined');
    // No readable transcript at all.
    expect(classify([], { transcriptRows: null })).toBe('undetermined');
    // A transcript that starts after the row existed may not be the one its claimant wrote.
    expect(classify([assistant(CREATED + 1_000), nativeQueue('enqueue', PROMPT, CREATED + 2_000)])).toBe('undetermined');
  });

  it('only counts the predecessor window, after the row existed and before this runner started', () => {
    // The same text sent earlier was an older message; one after the restart is this runner's own.
    expect(classify([userPrompt(PROMPT, CREATED - 60_000), userPrompt(PROMPT, RESTART + 5_000)])).toBe('not_received');
    // Sidechain and meta rows are not the main conversation receiving the prompt.
    expect(classify([
      assistant(CREATED - 1_000),
      userPrompt(PROMPT, CREATED + 1_000, { isSidechain: true }),
      userPrompt(PROMPT, CREATED + 2_000, { isMeta: true }),
    ])).toBe('not_received');
  });
});

describe('recoverClaudeUnifiedInheritedPendingDeliveries', () => {
  let dir: string | null = null;
  afterEach(async () => {
    if (dir) await rm(dir, { recursive: true, force: true });
    dir = null;
  });

  async function transcript(rows: readonly unknown[]): Promise<string> {
    dir = await mkdtemp(join(tmpdir(), 'inherited-delivery-'));
    const path = join(dir, 'claude-1.jsonl');
    await writeFile(path, `${rows.map((row) => JSON.stringify(row)).join('\n')}\n`);
    return path;
  }

  const inherited = (localId: string, text: string, extra: Partial<InheritedUncertainPendingDelivery> = {}): InheritedUncertainPendingDelivery => ({
    localId,
    createdAt: CREATED,
    requestedAction: { v: 1, kind: 'enqueue' },
    message: { role: 'user', content: { type: 'text', text } } as InheritedUncertainPendingDelivery['message'],
    earlierQueuedLocalIds: [],
    ...extra,
  });

  function client(rows: InheritedUncertainPendingDelivery[], settled: boolean = true) {
    return {
      listInheritedUncertainPendingDeliveries: vi.fn(async () => rows),
      settleInheritedPendingDeliveryAccepted: vi.fn(async () => settled),
      resendInheritedPendingDeliveryAsNew: vi.fn(async () => true),
    };
  }

  it('settles what the predecessor consumed, resends what it never got, and leaves the rest to the owner', async () => {
    const path = await transcript([
      assistant(CREATED - 1_000),
      userPrompt('primero', CREATED + 10_000),
      nativeQueue('enqueue', 'segundo', CREATED + 20_000),
      userPrompt('tercero', CREATED + 30_000),
      userPrompt('tercero', CREATED + 40_000),
    ]);
    const port = client([
      inherited('consumed', 'primero'),
      inherited('lost', 'segundo', { earlierQueuedLocalIds: ['consumed'] }),
      inherited('ambiguous', 'tercero', { earlierQueuedLocalIds: ['consumed', 'lost'] }),
      inherited('unreadable', 'x', { message: null }),
    ]);

    const decisions = await recoverClaudeUnifiedInheritedPendingDeliveries({
      client: port, transcriptPath: path, predecessorConfirmedDead: true, evidenceBeforeMs: RESTART,
    });

    expect(decisions).toEqual([
      { localId: 'consumed', verdict: 'received', outcome: 'settled' },
      { localId: 'lost', verdict: 'not_received', outcome: 'resent' },
      { localId: 'ambiguous', verdict: 'undetermined', outcome: 'left' },
      { localId: 'unreadable', verdict: 'undetermined', outcome: 'left' },
    ]);
    expect(port.settleInheritedPendingDeliveryAccepted).toHaveBeenCalledTimes(1);
    expect(port.settleInheritedPendingDeliveryAccepted).toHaveBeenCalledWith('consumed');
    expect(port.resendInheritedPendingDeliveryAsNew).toHaveBeenCalledTimes(1);
    expect(port.resendInheritedPendingDeliveryAsNew).toHaveBeenCalledWith('lost');
  });

  it('does not settle an ordinary row behind one still unresolved, which the server would refuse', async () => {
    const path = await transcript([
      assistant(CREATED - 1_000),
      userPrompt('tercero', CREATED + 1_000), userPrompt('tercero', CREATED + 2_000),
      userPrompt('cuarto', CREATED + 3_000), userPrompt('quinto', CREATED + 4_000),
    ]);
    const port = client([
      inherited('ambiguous', 'tercero'),
      inherited('behind', 'cuarto', { earlierQueuedLocalIds: ['ambiguous'] }),
      // An exact action is settled out of order, as the server allows.
      inherited('steer', 'quinto', { earlierQueuedLocalIds: ['ambiguous', 'behind'], requestedAction: { v: 1, kind: 'steer_if_active' } }),
    ]);

    const decisions = await recoverClaudeUnifiedInheritedPendingDeliveries({
      client: port, transcriptPath: path, predecessorConfirmedDead: false, evidenceBeforeMs: RESTART,
    });

    expect(decisions.map((decision) => [decision.localId, decision.outcome])).toEqual([
      ['ambiguous', 'left'],
      ['behind', 'left'],
      ['steer', 'settled'],
    ]);
    expect(port.settleInheritedPendingDeliveryAccepted).toHaveBeenCalledTimes(1);
    expect(port.settleInheritedPendingDeliveryAccepted).toHaveBeenCalledWith('steer');
  });
});

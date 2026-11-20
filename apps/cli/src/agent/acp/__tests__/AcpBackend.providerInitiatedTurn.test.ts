import { describe, expect, it } from 'vitest';
import { AcpBackend } from '../AcpBackend';
import type { AgentMessage } from '@/agent/core';
import { writeAcpTestAgentScript } from '../testkit/subprocessHarness';
import { withTempDir } from '@/testkit/fs/tempDir';
import { buildKimiAutonomousTurnHandlers, KIMI_AUTONOMOUS_TURNS_CAPABILITY } from '@/backends/kimi/acp/autonomousTurns';

const SESSION = 'autonomous-fixture-session';
const started = (turnId: number) => ({ sessionId: SESSION, turnId, event: 'started' });
const chunk = (turnId: number, text: string) => ({ sessionId: SESSION, turnId, event: 'update', update: {
  sessionUpdate: 'agent_message_chunk', content: { type: 'text', text },
} });
const ended = (turnId: number) => ({ sessionId: SESSION, turnId, event: 'ended', stopReason: 'end_turn' });
const text = (events: AgentMessage[]) => events.flatMap(event => event.type === 'model-output' ? [event.textDelta ?? event.fullText] : []);

async function withBackend(scenario: 'ordinary' | 'racing-start' | 'response-before-auto', run: (backend: AcpBackend, events: AgentMessage[]) => Promise<void>, capability: boolean | 'absent' = true) {
  await withTempDir('happier-acp-autonomous-', async dir => {
    // The fake process is the genuine SDK/stdio boundary. No provider or internal domain is mocked.
    const scriptPath = writeAcpTestAgentScript({ dir, fileName: 'autonomous-agent.mjs', source: `
      import { createInterface } from 'node:readline';
      let prompt = null;
      let capability = null;
      const send = value => process.stdout.write(JSON.stringify(value) + '\\n');
      const ok = (id, result = {}) => send({ jsonrpc: '2.0', id, result });
      const notify = params => send({ jsonrpc: '2.0', method: '_kimi/autonomous_turn', params });
      createInterface({ input: process.stdin }).on('line', line => {
        const request = JSON.parse(line);
        if (request.method === 'initialize') {
          capability = request.params.clientCapabilities?._meta?.['kimi/autonomous-turns'];
          ok(request.id, { protocolVersion: 1, authMethods: [], agentCapabilities: { _meta: { ${capability === 'absent' ? '' : `'kimi/autonomous-turns': ${capability}`} } } });
        } else if (request.method === 'session/new') ok(request.id, { sessionId: '${SESSION}' });
        else if (request.method === 'session/prompt') {
          prompt = request.id;
          if (${JSON.stringify(scenario)} === 'response-before-auto') {
            ok(prompt, { stopReason: 'end_turn' }); prompt = null;
            notify({ sessionId: '${SESSION}', turnId: 32, event: 'started' });
            notify({ sessionId: '${SESSION}', turnId: 32, event: 'update', update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'immediate background result' } } });
            notify({ sessionId: '${SESSION}', turnId: 32, event: 'ended', stopReason: 'end_turn' });
          }
          if (${JSON.stringify(scenario)} === 'racing-start') {
            notify({ sessionId: '${SESSION}', turnId: 31, event: 'started' });
            notify({ sessionId: '${SESSION}', turnId: 31, event: 'update', update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'auto-race' } } });
          }
        } else if (request.method === '_test/events') {
          for (const event of request.params.events) notify(event);
          ok(request.id);
        } else if (request.method === '_test/state') ok(request.id, { pendingPrompt: prompt !== null, capability });
        else if (request.method === '_test/complete-prompt') {
          send({ jsonrpc: '2.0', method: 'session/update', params: { sessionId: '${SESSION}', update: { sessionUpdate: 'plan', entries: [{ content: 'host plan', priority: 'medium', status: 'pending' }] } } });
          send({ jsonrpc: '2.0', method: 'session/update', params: { sessionId: '${SESSION}', update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'host-answer' } } } });
          ok(prompt, { stopReason: 'end_turn' }); prompt = null; ok(request.id);
        } else if (request.method === 'session/cancel') {
          if (prompt !== null) { ok(prompt, { stopReason: 'cancelled' }); prompt = null; }
        } else if (request.id !== undefined) ok(request.id);
      });
    ` });
    const backend = new AcpBackend({ agentName: 'test', cwd: dir, command: process.execPath, args: [scriptPath],
      initializeClientCapabilitiesMeta: { [KIMI_AUTONOMOUS_TURNS_CAPABILITY]: true },
      extensionHandlers: buildKimiAutonomousTurnHandlers(),
    });
    backend.setPlanStatePublisher(async () => {});
    const events: AgentMessage[] = [];
    backend.onMessage(event => events.push(event));
    try { await backend.startSession(); events.length = 0; await run(backend, events); }
    finally { await backend.dispose(); }
  });
}

const inject = (backend: AcpBackend, events: unknown[]) => backend.requestExtension('_test/events', { events });

describe('AcpBackend provider-initiated turns over negotiated SDK notifications', () => {
  it('delivers an idle autonomous message and tool result, then closes only on explicit ended', async () => {
    await withBackend('ordinary', async (backend, events) => {
      await inject(backend, [started(17), chunk(17, 'background result'), { sessionId: SESSION, turnId: 17, event: 'update', update: {
        sessionUpdate: 'tool_call', toolCallId: 'auto-tool', title: 'Read', kind: 'read', status: 'in_progress', rawInput: { path: '/tmp/synthetic-output' },
      } }, { sessionId: SESSION, turnId: 17, event: 'update', update: {
        sessionUpdate: 'tool_call_update', toolCallId: 'auto-tool', status: 'completed', rawOutput: { output: 'done' },
      } }]);
      await expect.poll(() => text(events)).toEqual(['background result']);
      expect(events).toContainEqual(expect.objectContaining({ type: 'tool-result', callId: 'auto-tool' }));
      expect(events.filter(event => event.type === 'status' && event.status === 'idle')).toEqual([]);
      await inject(backend, [ended(17)]);
      await expect.poll(() => events.some(event => event.type === 'status' && event.status === 'idle' && event.turnFinished)).toBe(true);
    });
  });

  it('rejects wrong sessions and updates after ended or cancellation without weakening ordinary late filtering', async () => {
    await withBackend('ordinary', async (backend, events) => {
      await inject(backend, [{ ...started(8), sessionId: 'other-session' }, chunk(8, 'wrong'), started(9), chunk(9, 'accepted'), ended(9), chunk(9, 'late'), started(9)]);
      await expect.poll(() => text(events)).toEqual(['accepted']);
      await inject(backend, [started(10), chunk(10, 'before-cancel')]);
      await expect.poll(() => text(events)).toEqual(['accepted', 'before-cancel']);
      await backend.cancel(SESSION);
      await inject(backend, [chunk(10, 'after-cancel'), ended(10), started(10), chunk(10, 'reopened')]);
      expect(text(events)).toEqual(['accepted', 'before-cancel']);
    });
  });

  it.each(['ordinary', 'racing-start'] as const)('keeps a user prompt pending across autonomous ended (%s)', async scenario => {
    await withBackend(scenario, async (backend, events) => {
      const plans: unknown[] = [];
      backend.setPlanStatePublisher(async plan => { plans.push(plan); });
      if (scenario === 'ordinary') await inject(backend, [started(31), chunk(31, 'auto-first')]);
      await backend.sendPrompt(SESSION, 'user follow-up');
      expect(await backend.requestExtension('_test/state')).toMatchObject({ pendingPrompt: true });
      await expect.poll(() => text(events)).toEqual([scenario === 'ordinary' ? 'auto-first' : 'auto-race']);
      let completed = false;
      const completion = backend.waitForResponseComplete().then(() => { completed = true; });
      await inject(backend, [ended(31)]);
      expect(completed).toBe(false);
      expect(events.filter(event => event.type === 'status' && event.status === 'idle')).toEqual([]);
      await backend.requestExtension('_test/complete-prompt');
      await completion;
      expect(text(events)).toEqual([scenario === 'ordinary' ? 'auto-first' : 'auto-race', 'host-answer']);
      await expect.poll(() => plans).toContainEqual(expect.objectContaining({ items: [expect.objectContaining({ title: 'host plan' })] }));
      expect(events.filter(event => event.type === 'status' && event.status === 'idle')).toHaveLength(1);
    });
  });

  it('delivers an autonomous turn immediately following the normal prompt response on stdio', async () => {
    await withBackend('response-before-auto', async (backend, events) => {
      await backend.sendPrompt(SESSION, 'start background work');
      await backend.waitForResponseComplete();
      await expect.poll(() => text(events)).toEqual(['immediate background result']);
    });
  });

  it('preserves a pending user RPC after an autonomous segment fails', async () => {
    await withBackend('ordinary', async (backend, events) => {
      await inject(backend, [started(35), chunk(35, 'partial auto')]);
      await backend.sendPrompt(SESSION, 'user follow-up');
      const completion = backend.waitForResponseComplete();
      await inject(backend, [{ ...ended(35), error: 'Autonomous turn failed' }]);
      await expect.poll(() => events.some(event => event.type === 'event' && event.name === 'provider-initiated-turn-error')).toBe(true);
      expect(events.some(event => event.type === 'status' && (event.status === 'error' || event.status === 'idle'))).toBe(false);
      await backend.requestExtension('_test/complete-prompt');
      await completion;
      expect(text(events)).toEqual(['partial auto', 'host-answer']);
    });
  });

  it('reports an autonomous failure instead of a successful idle completion', async () => {
    await withBackend('ordinary', async (backend, events) => {
      await inject(backend, [started(41), chunk(41, 'partial')]);
      await expect.poll(() => text(events)).toEqual(['partial']);
      const completion = backend.waitForResponseComplete();
      const rejected = expect(completion).rejects.toThrow('Autonomous turn failed');
      await inject(backend, [{ ...ended(41), error: 'Autonomous turn failed' }]);
      await rejected;
      expect(events).toContainEqual(expect.objectContaining({ type: 'status', status: 'error' }));
      expect(events.filter(event => event.type === 'status' && event.status === 'idle')).toEqual([]);
    });
  });

  it.each([false, 'absent'] as const)('does not admit the extension when peer support is %s', async capability => {
    await withBackend('ordinary', async (backend, events) => {
      await inject(backend, [started(1), chunk(1, 'unsupported'), ended(1)]);
      expect(text(events)).toEqual([]);
    }, capability);
  });
});

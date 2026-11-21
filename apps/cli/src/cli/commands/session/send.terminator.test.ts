import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { createHappierMcpServer } from '@/mcp/createHappierMcpServer';
import Fastify from 'fastify';
import { expect, it, vi } from 'vitest';

import { bindApiSessionSocketMock, createApiSessionSocketStub } from '@/testkit/backends/apiSessionSocketHarness';
import { installAxiosFastifyAdapter } from '@/testkit/http/axiosAdapter';
import { captureConsoleJsonOutput } from '@/testkit/logger/captureOutput';
import { reloadConfiguration } from '@/configuration';
import { handleSessionCommand } from './handleSessionCommand';

const { mockIo } = vi.hoisted(() => ({ mockIo: vi.fn() }));
// Only relay HTTP and socket transports are substituted; the send owners are real.
vi.mock('socket.io-client', () => ({ io: mockIo }));

it.each([
  { route: 'cli', senderSessionId: '' },
  { route: 'cli', senderSessionId: 'c987654321098765432109876' },
  { route: 'mcp', senderSessionId: 'c987654321098765432109876' },
] as const)('persists exact text and known origin through $route (source=$senderSessionId)', async ({ route, senderSessionId }) => {
  const sessionId = 'c123456789012345678901234';
  const selectedLocalId = 'claim-1';
  const app = Fastify();
  let localId = '';
  let admittedContent: unknown;
  const user = () => ({ id: 'msg-user', seq: 1, localId, createdAt: 1, updatedAt: 1,
    content: { t: 'plain', v: { role: 'user', content: { type: 'text', text: '-message' } } } });
  app.all('*', async (request, reply) => {
    const path = request.url.split('?')[0];
    const session = { id: sessionId, seq: 2, createdAt: 1, updatedAt: 2, active: true, activeAt: 1,
      encryptionMode: 'plain', metadata: '{}', metadataVersion: 1,
      agentState: null, agentStateVersion: 0, dataEncryptionKey: null };
    if (path === `/v2/sessions/${sessionId}`) return { session };
    if (path === '/v2/sessions' || path === '/v2/sessions/archived') return { sessions: [session], hasNext: false, nextCursor: null };
    if (path === '/v1/account/encryption/currentness') return {
      mode: 'plain', version: 1, signingKeyFingerprint: null, contentKeyFingerprint: null, updatedAt: 1,
    };
    if (path === '/v2/account/settings') return { version: 1, content: { t: 'plain', v: {} } };
    if (request.method === 'POST' && path === `/v2/sessions/${sessionId}/pending`) {
      const body = request.body as { localId: string; content: unknown };
      localId = body.localId;
      admittedContent = body.content;
      return { didWrite: true };
    }
    if (path === `/v2/sessions/${sessionId}/messages/by-local-id/${encodeURIComponent(localId)}`) {
      return { message: user() };
    }
    if (path === `/v1/sessions/${sessionId}/messages`) return { messages: [user(), {
      id: 'msg-complete', seq: 2, localId: null, createdAt: 2, updatedAt: 2,
      content: { t: 'plain', v: { role: 'agent', content: { type: 'event', data: { type: 'task_complete' } } } },
    }] };
    return reply.code(404).send({ error: 'unexpected_fixture_route', path });
  });
  const restoreHttp = installAxiosFastifyAdapter({ app, origin: 'http://relay.test' });
  vi.stubEnv('HAPPIER_SERVER_URL', 'http://relay.test');
  vi.stubEnv('HAPPIER_LOCAL_SERVER_URL', 'http://relay.test');
  vi.stubEnv('HAPPIER_SESSION_ID', route === 'cli' ? senderSessionId : '');
  bindApiSessionSocketMock(mockIo, createApiSessionSocketStub({ emit: (_event, args) => {
    const acknowledge = args[1];
    if (typeof acknowledge === 'function') acknowledge({ ok: true, result: { ok: true } });
  } }));
  const output = captureConsoleJsonOutput();
  try {
    reloadConfiguration();
    const credentials = { token: 'fixture_token', encryption: { type: 'legacy' as const, secret: new Uint8Array(32).fill(7) } };
    const target = senderSessionId ? sessionId.slice(0, 8) : sessionId;
    if (route === 'cli') {
      await handleSessionCommand(['send', target, '--local-id', selectedLocalId, '--', '-message', '--json', '--wait'], {
        readCredentialsFn: async () => credentials,
      });
      expect(output.json()).toMatchObject({ ok: true, kind: 'session_send', data: { sessionId, localId: selectedLocalId, waited: true } });
    } else {
      const { mcp } = createHappierMcpServer({
        sessionId: senderSessionId,
        rpcHandlerManager: { registerHandler: () => {}, invokeLocal: async () => ({}) },
        sendClaudeSessionMessage: () => {}, updateMetadata: () => {},
      }, { credentials });
      const client = new Client({ name: 'session-message-origin', version: '1.0.0' });
      const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
      try {
        await mcp.connect(serverTransport); await client.connect(clientTransport);
        const result = await client.callTool({ name: 'action_execute', arguments: {
          actionId: 'session.message.send', input: { sessionId: target, message: '-message', wait: true },
        } });
        expect(result.isError, JSON.stringify(result)).toBe(false);
      } finally { await client.close(); await mcp.close(); }
    }
    expect(admittedContent).toMatchObject({ t: 'plain', v: { role: 'user', content: { type: 'text', text: '-message' }, meta: { source: 'ui', sentFrom: 'cli' } } });
    if (senderSessionId) {
      expect(admittedContent).toMatchObject({ t: 'plain', v: { meta: { happier: {
        kind: 'session_message.v1', payload: { senderSessionId, targetSessionId: sessionId },
      } } } });
    } else {
      expect(admittedContent).not.toHaveProperty('v.meta.happier');
    }
    expect(user()).toMatchObject({ localId: route === 'cli' ? selectedLocalId : expect.any(String), content: { t: 'plain', v: { content: { text: '-message' } } } });
  } finally {
    output.restore();
    restoreHttp();
    vi.unstubAllEnvs();
    await app.close();
  }
  if (route === 'mcp') process.stdout.write('SESSION_MESSAGE_WIRE ' + JSON.stringify(admittedContent) + '\n');
});

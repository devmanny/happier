import { describe, expect, it } from 'vitest';

import type { MessageSearchSetRequestV1, MessageSearchStatusV1 } from '@happier-dev/protocol';

import { createDaemonControlApp, type DaemonMessageSearchControl } from './controlServer';

function app(messageSearch?: DaemonMessageSearchControl) {
  return createDaemonControlApp({
    getChildren: () => [],
    machineId: 'machine_local',
    stopSession: async () => ({ status: 'not_found' as const }),
    spawnSession: async () => ({ type: 'success', sessionId: 'happy-test-123' }),
    requestShutdown: () => {},
    onHappySessionWebhook: () => {},
    controlToken: 'test-token',
    ...(messageSearch ? { messageSearch } : {}),
  });
}

const headers = { 'Content-Type': 'application/json', 'x-happier-daemon-token': 'test-token' };

describe('daemon control server: conversation search (happier search)', () => {
  it('switches search through the memory worker and reports its status', async () => {
    const sets: MessageSearchSetRequestV1[] = [];
    const status: MessageSearchStatusV1 = { v: 1, enabled: true, state: 'indexing', coverage: null, indexBytes: 1024 };
    const control = app({ status: async () => status, set: async (request) => { sets.push(request); return status; } });
    try {
      await control.ready();
      const set = await control.inject({ method: 'POST', url: '/memory/message-search/set', headers, payload: JSON.stringify({ v: 1, enabled: true }) });
      expect(set.statusCode).toBe(200);
      expect(set.json()).toEqual(status);
      expect(sets).toEqual([{ v: 1, enabled: true, deleteIndex: false }]);

      const bad = await control.inject({ method: 'POST', url: '/memory/message-search/set', headers, payload: JSON.stringify({ v: 1 }) });
      expect(bad.statusCode).toBe(400);
      const anonymous = await control.inject({ method: 'POST', url: '/memory/message-search/status', headers: { 'Content-Type': 'application/json' }, payload: '{}' });
      expect(anonymous.statusCode).toBe(401);
    } finally {
      await control.close();
    }
  });

  it('answers 503 while the memory worker is not running', async () => {
    const control = app({ status: async () => null, set: async () => null });
    try {
      await control.ready();
      const response = await control.inject({ method: 'POST', url: '/memory/message-search/status', headers, payload: '{}' });
      expect(response.statusCode).toBe(503);
      expect(response.json()).toEqual({ ok: false, errorCode: 'message_search_unavailable' });
    } finally {
      await control.close();
    }
  });
});

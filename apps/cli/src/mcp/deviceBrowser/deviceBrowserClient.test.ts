import { describe, expect, it, vi } from 'vitest';
import { RPC_ERROR_CODES } from '@happier-dev/protocol/rpc';
import { RpcError } from '@happier-dev/protocol/rpcErrors';

import { createDeviceBrowserClient } from './deviceBrowserClient';

const device = { name: 'Mac mini', platform: 'macos' as const };

function methodNotAvailable(): Error {
  return new RpcError('RPC method not available', RPC_ERROR_CODES.METHOD_NOT_AVAILABLE);
}

describe('createDeviceBrowserClient', () => {
  it('prefers the focused device and falls back to the host only when nobody serves the focused slot', async () => {
    const transport = vi.fn(async ({ method }: { method: string }) => {
      if (method === 'device.browser.v1.focused') throw methodNotAvailable();
      return { ok: true, device, text: 'hello' };
    });
    const client = createDeviceBrowserClient(transport, { sessionId: 'sess_a' });

    await expect(client.invoke({ op: 'snapshot' })).resolves.toEqual({ ok: true, device, text: 'hello' });
    expect(transport.mock.calls.map(([call]) => call.method)).toEqual([
      'device.browser.v1.focused',
      'device.browser.v1.host',
    ]);
  });

  it('never re-sends a request that reached a device, even when it failed', async () => {
    const transport = vi.fn(async () => { throw new Error('Machine RPC call timeout'); });
    const client = createDeviceBrowserClient(transport, { sessionId: 'sess_a' });

    const result = await client.invoke({ op: 'click', ref: 'e1' });
    expect(result).toMatchObject({ ok: false, errorCode: 'unavailable' });
    expect(transport).toHaveBeenCalledTimes(1);
  });

  it('reports a typed unavailable failure when no app serves any slot', async () => {
    const client = createDeviceBrowserClient(async () => { throw methodNotAvailable(); }, { sessionId: 'sess_a' });
    await expect(client.invoke({ op: 'tabs', action: 'list' })).resolves.toMatchObject({ ok: false, errorCode: 'unavailable' });
  });

  it('rejects invalid requests locally and unrecognized device answers', async () => {
    const transport = vi.fn(async () => ({ ok: true, device: { name: 'x', platform: 'android' } }));
    const client = createDeviceBrowserClient(transport, { sessionId: 'sess_a' });

    await expect(client.invoke({ op: 'click' })).resolves.toMatchObject({ ok: false, errorCode: 'invalid_request' });
    expect(transport).not.toHaveBeenCalled();
    await expect(client.invoke({ op: 'snapshot' })).resolves.toMatchObject({ ok: false, errorCode: 'unavailable' });
  });

  it('gives waits enough relay time to answer with their own timeout', async () => {
    const transport = vi.fn(async () => ({ ok: true, device }));
    const client = createDeviceBrowserClient(transport, { sessionId: 'sess_a' });
    await client.invoke({ op: 'wait', text: 'Done', timeoutMs: 90_000 });
    expect((transport.mock.calls[0] as unknown as [{ timeoutMs: number }])[0].timeoutMs).toBeGreaterThan(90_000);
  });
  it('always acts for the calling session, whatever session an agent names', async () => {
    const transport = vi.fn(async () => ({ ok: true, device }));
    const client = createDeviceBrowserClient(transport, { sessionId: 'sess_caller' });

    await client.invoke({ op: 'tabs', action: 'list', sessionId: 'sess_other' });
    await client.invoke({ op: 'snapshot' });

    expect(transport.mock.calls.map((call) => (call as unknown as [{ request: { sessionId: string } }])[0].request.sessionId))
      .toEqual(['sess_caller', 'sess_caller']);
  });
});

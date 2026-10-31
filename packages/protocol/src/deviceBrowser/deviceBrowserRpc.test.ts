import { describe, expect, it } from 'vitest';

import {
  DEVICE_BROWSER_RPC_SLOTS,
  DeviceBrowserRequestSchema,
  DeviceBrowserResponseSchema,
  deviceBrowserRpcMethod,
} from './deviceBrowserRpc.js';

describe('device browser RPC contract', () => {
  it('addresses the focused device before the always-on host, under the machine namespace', () => {
    expect(DEVICE_BROWSER_RPC_SLOTS).toEqual(['focused', 'host']);
    expect(deviceBrowserRpcMethod('focused')).toBe('device.browser.v1.focused');
    expect(deviceBrowserRpcMethod('host')).toBe('device.browser.v1.host');
  });

  it('accepts each tool operation and rejects ambiguous element targets', () => {
    for (const request of [
      { op: 'status' },
      { op: 'navigate', url: 'https://example.com', newTab: true },
      { op: 'navigate', action: 'back' },
      { op: 'screenshot', fullPage: true },
      { op: 'snapshot', maxChars: 1000 },
      { op: 'click', ref: 'e3' },
      { op: 'type', selector: '#q', text: 'hola', submit: true },
      { op: 'scroll', deltaY: 400 },
      { op: 'evaluate', script: 'document.title' },
      { op: 'wait', text: 'Listo', timeoutMs: 5000 },
      { op: 'tabs', action: 'select', tabId: 't1' },
    ]) {
      expect(DeviceBrowserRequestSchema.safeParse(request).success, JSON.stringify(request)).toBe(true);
    }
    for (const request of [
      { op: 'navigate' },
      { op: 'click' },
      { op: 'click', ref: 'e1', selector: 'a' },
      { op: 'type', ref: 'e1' },
      { op: 'wait', timeoutMs: 5000 },
      { op: 'wait', durationMs: 10, timeoutMs: 999_999 },
      { op: 'tabs', action: 'select' },
      { op: 'unknown' },
    ]) {
      expect(DeviceBrowserRequestSchema.safeParse(request).success, JSON.stringify(request)).toBe(false);
    }
  });

  it('parses device success and typed failure responses', () => {
    const ok = DeviceBrowserResponseSchema.parse({
      ok: true,
      device: { name: 'Mac mini', platform: 'macos' },
      tab: { id: 't1', url: 'https://example.com/', title: 'Example', selected: true, loading: false },
      image: { mimeType: 'image/png', data: 'iVBORw0KGgo=', width: 10, height: 20 },
    });
    expect(ok.ok).toBe(true);
    const failure = DeviceBrowserResponseSchema.parse({ ok: false, errorCode: 'element_not_found', error: 'No element e9' });
    expect(failure).toEqual({ ok: false, errorCode: 'element_not_found', error: 'No element e9' });
    expect(DeviceBrowserResponseSchema.safeParse({ ok: false, errorCode: 'nope', error: 'x' }).success).toBe(false);
  });
});

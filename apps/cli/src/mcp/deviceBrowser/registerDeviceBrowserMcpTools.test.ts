import { describe, expect, it, vi } from 'vitest';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';

import { DEVICE_BROWSER_MCP_TOOL_NAMES, registerDeviceBrowserMcpTools } from './registerDeviceBrowserMcpTools';

async function connect(invoke: (request: unknown) => Promise<unknown>) {
  const server = new McpServer({ name: 'test', version: '1.0.0' });
  registerDeviceBrowserMcpTools(server, { invoke: invoke as never });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  const client = new Client({ name: 'client', version: '1.0.0' });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
  return client;
}

const device = { name: 'Mac mini', platform: 'macos' };

describe('registerDeviceBrowserMcpTools', () => {
  it('exposes the browser tool family', async () => {
    const client = await connect(async () => ({ ok: true, device }));
    const { tools } = await client.listTools();
    expect(tools.map((tool) => tool.name).sort()).toEqual([...DEVICE_BROWSER_MCP_TOOL_NAMES].sort());
    expect(DEVICE_BROWSER_MCP_TOOL_NAMES).toEqual(expect.arrayContaining([
      'browser_navigate', 'browser_screenshot', 'browser_snapshot', 'browser_click', 'browser_type',
      'browser_scroll', 'browser_evaluate', 'browser_wait', 'browser_tabs',
    ]));
  });

  it('maps tool arguments to device operations and returns screenshots as images', async () => {
    const invoke = vi.fn(async () => ({
      ok: true,
      device,
      image: { mimeType: 'image/png', data: 'iVBORw0KGgo=', width: 4, height: 2 },
    }));
    const client = await connect(invoke);

    const result = await client.callTool({ name: 'browser_screenshot', arguments: { fullPage: true } });
    expect(invoke).toHaveBeenCalledWith({ op: 'screenshot', fullPage: true });
    const content = result.content as Array<{ type: string; data?: string; mimeType?: string; text?: string }>;
    expect(content[0]).toEqual({ type: 'image', data: 'iVBORw0KGgo=', mimeType: 'image/png' });
    expect(content[1]?.type).toBe('text');
    expect(content[1]?.text).not.toContain('iVBORw0KGgo=');
    expect(result.isError).toBeFalsy();
  });

  it('surfaces device failures as tool errors', async () => {
    const client = await connect(async () => ({ ok: false, errorCode: 'element_not_found', error: 'No element e9' }));
    const result = await client.callTool({ name: 'browser_click', arguments: { ref: 'e9' } });
    expect(result.isError).toBe(true);
    expect(JSON.stringify(result.content)).toContain('element_not_found');
  });
});

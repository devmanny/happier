import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';

import { DEVICE_BROWSER_MAX_WAIT_MS, type DeviceBrowserResponse } from '@happier-dev/protocol';

import { DEVICE_BROWSER_MCP_TOOL_NAMES, type DeviceBrowserMcpToolName } from './deviceBrowserToolNames';

export { DEVICE_BROWSER_MCP_TOOL_NAMES };

type Invoke = (request: unknown) => Promise<DeviceBrowserResponse>;

const tabId = z.string().optional().describe('One of this session\'s tab ids from browser_tabs; defaults to this session\'s current tab.');
const ref = z.string().optional().describe('Element ref from the latest browser_snapshot (e.g. "e12").');
const selector = z.string().optional().describe('CSS selector, used when no ref is given.');

export type ToolSpec = Readonly<{
  name: DeviceBrowserMcpToolName;
  title: string;
  description: string;
  inputSchema: Record<string, z.ZodType>;
  toRequest: (args: Record<string, unknown>) => Record<string, unknown>;
}>;

const withOp = (op: string) => (args: Record<string, unknown>) => ({ op, ...args });

/**
 * The browser tools: one definition list for the session MCP server (which runs them) and the
 * stdio bridge providers use (which forwards them to that server).
 */
export const DEVICE_BROWSER_MCP_TOOLS: readonly ToolSpec[] = [
  {
    name: 'browser_navigate',
    title: 'Browser: navigate',
    description: 'Open a URL in this session\'s own tab of the integrated browser in the user\'s Happier app (iPhone, iPad or Mac), created on first use; or go back/forward/reload. Tabs share the browser\'s cookies and logins.',
    inputSchema: {
      url: z.string().optional().describe('URL to open (required unless action is back/forward/reload).'),
      action: z.enum(['go', 'back', 'forward', 'reload']).optional(),
      newTab: z.boolean().optional().describe('Open the URL in a new tab.'),
      tabId,
    },
    toRequest: withOp('navigate'),
  },
  {
    name: 'browser_screenshot',
    title: 'Browser: screenshot',
    description: 'Capture a PNG screenshot of a tab in the integrated browser.',
    inputSchema: { fullPage: z.boolean().optional().describe('Capture the whole page instead of the viewport.'), tabId },
    toRequest: withOp('screenshot'),
  },
  {
    name: 'browser_snapshot',
    title: 'Browser: snapshot',
    description: 'Read the page as text with interactive elements labelled [ref=eN]; use the refs with browser_click/browser_type/browser_scroll. Refs are valid until the next snapshot.',
    inputSchema: { maxChars: z.number().int().positive().optional(), tabId },
    toRequest: withOp('snapshot'),
  },
  {
    name: 'browser_click',
    title: 'Browser: click',
    description: 'Click an element by snapshot ref or CSS selector.',
    inputSchema: { ref, selector, tabId },
    toRequest: withOp('click'),
  },
  {
    name: 'browser_type',
    title: 'Browser: type',
    description: 'Type text into an input, textarea or editable element (by ref/selector, or the focused element). Optionally clear it first and submit (Enter).',
    inputSchema: {
      text: z.string(),
      ref,
      selector,
      clear: z.boolean().optional(),
      submit: z.boolean().optional(),
      tabId,
    },
    toRequest: withOp('type'),
  },
  {
    name: 'browser_scroll',
    title: 'Browser: scroll',
    description: 'Scroll the page by a delta, to top/bottom, or bring an element (ref/selector) into view.',
    inputSchema: {
      deltaX: z.number().optional(),
      deltaY: z.number().optional(),
      to: z.enum(['top', 'bottom']).optional(),
      ref,
      selector,
      tabId,
    },
    toRequest: withOp('scroll'),
  },
  {
    name: 'browser_evaluate',
    title: 'Browser: evaluate JavaScript',
    description: 'Run JavaScript in the page and return its JSON-serializable result. The script is a function body: use `return` to produce a value; it may be async.',
    inputSchema: { script: z.string(), tabId },
    toRequest: withOp('evaluate'),
  },
  {
    name: 'browser_wait',
    title: 'Browser: wait',
    description: `Wait until a selector or text appears or the URL contains a string, or wait a fixed duration. Times out after timeoutMs (max ${DEVICE_BROWSER_MAX_WAIT_MS} ms).`,
    inputSchema: {
      selector,
      text: z.string().optional(),
      urlIncludes: z.string().optional(),
      durationMs: z.number().int().positive().optional(),
      timeoutMs: z.number().int().positive().optional(),
      tabId,
    },
    toRequest: withOp('wait'),
  },
  {
    name: 'browser_tabs',
    title: 'Browser: tabs',
    description: 'List, open, select or close this session\'s own tabs of the integrated browser (other sessions\' and the user\'s tabs are not visible). "select" changes which of them later calls use by default, not what the user sees. "list" also reports which device is answering.',
    inputSchema: {
      action: z.enum(['list', 'new', 'select', 'close']),
      tabId: z.string().optional(),
      url: z.string().optional().describe('URL for a new tab.'),
    },
    toRequest: withOp('tabs'),
  },
];

function formatResponse(response: DeviceBrowserResponse) {
  if (!response.ok) {
    return { content: [{ type: 'text' as const, text: JSON.stringify(response) }], isError: true };
  }
  const { image, ...rest } = response;
  const summary = image ? { ...rest, image: { mimeType: image.mimeType, width: image.width, height: image.height } } : rest;
  return {
    content: [
      ...(image ? [{ type: 'image' as const, data: image.data, mimeType: image.mimeType }] : []),
      { type: 'text' as const, text: JSON.stringify(summary) },
    ],
  };
}

/** Registers the `browser_*` tools that drive the integrated browser of the user's Happier app. */
export function registerDeviceBrowserMcpTools(server: McpServer, deps: Readonly<{ invoke: Invoke }>): void {
  for (const tool of DEVICE_BROWSER_MCP_TOOLS) {
    server.registerTool(
      tool.name,
      { title: tool.title, description: tool.description, inputSchema: tool.inputSchema },
      async (args: Record<string, unknown>) => formatResponse(await deps.invoke(tool.toRequest(args))),
    );
  }
}

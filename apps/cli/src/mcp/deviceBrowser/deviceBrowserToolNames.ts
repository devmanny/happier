/**
 * MCP tool names of the integrated browser (`registerDeviceBrowserMcpTools`). Manny's product
 * decision: agents drive this browser without a per-action confirmation, so these names are
 * trusted for auto-approval under the Happier MCP server prefixes only.
 */
export const DEVICE_BROWSER_MCP_TOOL_NAMES = [
  'browser_navigate',
  'browser_screenshot',
  'browser_snapshot',
  'browser_click',
  'browser_type',
  'browser_scroll',
  'browser_evaluate',
  'browser_wait',
  'browser_tabs',
] as const;
export type DeviceBrowserMcpToolName = (typeof DEVICE_BROWSER_MCP_TOOL_NAMES)[number];

const HAPPIER_MCP_PREFIXES = ['mcp__happier__', 'happier__', 'happier_'] as const;

export function isHappierDeviceBrowserToolName(toolName: string): boolean {
  const normalized = toolName.trim().toLowerCase();
  return HAPPIER_MCP_PREFIXES.some((prefix) =>
    normalized.startsWith(prefix)
    && (DEVICE_BROWSER_MCP_TOOL_NAMES as readonly string[]).includes(normalized.slice(prefix.length)));
}

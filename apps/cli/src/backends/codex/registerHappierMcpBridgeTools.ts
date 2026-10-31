import { listBuiltInHappierTools } from '@/agent/tools/happierTools/listBuiltInHappierTools';
import { DEVICE_BROWSER_MCP_TOOLS } from '@/mcp/deviceBrowser/registerDeviceBrowserMcpTools';

type ToolRegistrar = Readonly<{
  registerTool: (name: string, definition: any, handler: (args: any, extra?: unknown) => Promise<any>) => void;
}>;

export function registerHappierMcpBridgeTools(
  server: ToolRegistrar,
  deps: Readonly<{
    callHttpTool: (name: string, args: unknown, extra?: unknown) => Promise<any>;
  }>,
): void {
  const forward = (name: string) => async (args: any, extra?: unknown) => {
    try {
      return await deps.callHttpTool(name, args, extra);
    } catch (error) {
      return {
        content: [
          { type: 'text', text: `Failed to call tool ${name}: ${error instanceof Error ? error.message : String(error)}` },
        ],
        isError: true,
      };
    }
  };

  for (const tool of listBuiltInHappierTools({ surface: 'session_agent' })) {
    const meta = {
      description: tool.description,
      title: tool.title,
      inputSchema: tool.inputSchema,
      ...(tool.annotations === undefined ? {} : { annotations: tool.annotations }),
    };

    server.registerTool(tool.name, meta, forward(tool.name));
  }

  // The integrated browser tools run in the session MCP server; results (screenshots included)
  // pass through unchanged. Without a machine or credentials that server reports the tool missing.
  for (const tool of DEVICE_BROWSER_MCP_TOOLS) {
    server.registerTool(tool.name, { title: tool.title, description: tool.description, inputSchema: tool.inputSchema }, forward(tool.name));
  }
}

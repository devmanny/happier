import { beforeEach, describe, expect, it, vi } from 'vitest';
import { listBuiltInHappierTools } from '@/agent/tools/happierTools/listBuiltInHappierTools';

const env = process.env;

describe('registerHappierMcpBridgeTools', () => {
  beforeEach(() => {
    vi.resetModules();
    process.env = { ...env };
    delete process.env.HAPPIER_ACTIONS_SETTINGS_V1;
  });

  it('leaves current-session fields optional so the session server can fill them', async () => {
    const { registerHappierMcpBridgeTools } = await import('./registerHappierMcpBridgeTools');
    const calls: any[] = [];
    registerHappierMcpBridgeTools({
      registerTool: (name: string, definition: any) => { calls.push({ name, definition }); },
    } as any, { callHttpTool: async () => ({ content: [], isError: false }) });

    for (const name of ['quien_esta_aqui', 'session_goal_get']) {
      const schema = calls.find((c) => c.name === name)?.definition.inputSchema;
      expect(schema?.safeParse({}).success, name).toBe(true);
    }
  });

  it('registers only the currently enabled Happier MCP tools and forwards calls', async () => {
    process.env.HAPPIER_ACTIONS_SETTINGS_V1 = JSON.stringify({
      v: 1,
      actions: {
        'review.start': { enabled: true, disabledSurfaces: ['session_agent'], disabledPlacements: [] },
      },
    });

    const { registerHappierMcpBridgeTools } = await import('./registerHappierMcpBridgeTools');
    const calls: any[] = [];
    const registrar = {
      registerTool: (name: string, definition: any, handler: (args: any) => Promise<any>) => {
        calls.push({ name, definition, handler });
      },
    };

    const forwarded: any[] = [];
    registerHappierMcpBridgeTools(registrar as any, {
      callHttpTool: async (name: string, args: unknown, extra?: unknown) => {
        forwarded.push({ name, args, extra });
        return { content: [{ type: 'text', text: 'ok' }], isError: false };
      },
    });

    const names = calls.map((c) => c.name);
    expect(names.slice(0, listBuiltInHappierTools({ surface: 'session_agent' }).length))
      .toEqual(listBuiltInHappierTools({ surface: 'session_agent' }).map((tool) => tool.name));
    expect(names).toContain('change_title');
    expect(names).not.toContain('happier__change_title');
    expect(names).not.toContain('happy__change_title');
    expect(names).not.toContain('review_start');
    expect(names).not.toContain('subagents_plan_start');
    expect(names).not.toContain('subagents_delegate_start');
    expect(names).not.toContain('execution_run_start');

    const actionExecute = calls.find((c) => c.name === 'action_execute');
    expect(actionExecute).toBeTruthy();
    expect(actionExecute.definition).not.toHaveProperty('annotations');
    expect(calls.find((c) => c.name === 'execution_run_wait')?.definition.annotations).toEqual({
      readOnlyHint: true,
      destructiveHint: false,
    });
    const extra = {
      _meta: { progressToken: 'progress-1' },
      sendNotification: vi.fn(async () => undefined),
    };
    const res = await actionExecute.handler(
      {
        actionId: 'subagents.delegate.start',
        input: {
          instructions: 'Delegate.',
          backendTargetKeys: ['agent:claude'],
        },
      },
      extra,
    );
    expect(res.isError).toBe(false);
    expect(forwarded[0]).toEqual({
      name: 'action_execute',
      args: {
        actionId: 'subagents.delegate.start',
        input: {
          instructions: 'Delegate.',
          backendTargetKeys: ['agent:claude'],
        },
      },
      extra,
    });
  });
  it('exposes the integrated browser tools and forwards their results unchanged', async () => {
    const { registerHappierMcpBridgeTools } = await import('./registerHappierMcpBridgeTools');
    const calls: any[] = [];
    const screenshot = {
      content: [{ type: 'image', data: 'iVBORw0KGgo=', mimeType: 'image/png' }, { type: 'text', text: '{"ok":true}' }],
    };
    const forwarded: any[] = [];
    registerHappierMcpBridgeTools({ registerTool: (name: string, definition: any, handler: any) => calls.push({ name, definition, handler }) } as any, {
      callHttpTool: async (name: string, args: unknown) => {
        forwarded.push({ name, args });
        return screenshot;
      },
    });

    const names = calls.map((c) => c.name);
    for (const name of ['browser_navigate', 'browser_screenshot', 'browser_snapshot', 'browser_click', 'browser_type',
      'browser_scroll', 'browser_evaluate', 'browser_wait', 'browser_tabs']) {
      expect(names).toContain(name);
    }
    const tool = calls.find((c) => c.name === 'browser_screenshot');
    await expect(tool.handler({ fullPage: true })).resolves.toEqual(screenshot);
    expect(forwarded).toEqual([{ name: 'browser_screenshot', args: { fullPage: true } }]);
  });
});

import { describe, expect, it, vi } from 'vitest';

import type { EnhancedMode } from '../../loop';
import type { PermissionResult } from '../../sdk/types';
import { buildClaudeAgentSdkHooks } from './buildClaudeAgentSdkHooks';

const makeMode = (): EnhancedMode => ({
  permissionMode: 'default',
});

function buildHooks(
  canCallTool = vi.fn(async (): Promise<PermissionResult> => ({ behavior: 'deny', message: 'denied' })),
) {
  return buildClaudeAgentSdkHooks({
    cwd: '/tmp/project',
    claudeConfigDir: null,
    getMode: makeMode,
    onSessionFound: () => {},
    onSessionHook: () => {},
    canCallTool,
  });
}

describe('buildClaudeAgentSdkHooks', () => {
  it('preserves authoritative SessionStart source evidence for runtime-activity startup', async () => {
    const onSessionFound = vi.fn();
    const { hooks } = buildClaudeAgentSdkHooks({
      cwd: '/tmp/project',
      claudeConfigDir: null,
      getMode: makeMode,
      onSessionFound,
      onSessionHook: () => {},
      canCallTool: vi.fn(async (): Promise<PermissionResult> => ({ behavior: 'deny', message: 'denied' })),
    });
    const sessionStart = hooks.SessionStart as Array<{ hooks: Array<(input: unknown) => Promise<unknown>> }>;

    await sessionStart[0]!.hooks[0]!({
      session_id: 'claude-new',
      transcript_path: '/tmp/claude-new.jsonl',
      hook_event_name: 'SessionStart',
      source: 'startup',
    });

    expect(onSessionFound).toHaveBeenCalledWith('claude-new', {
      transcript_path: '/tmp/claude-new.jsonl',
      transcriptPath: '/tmp/claude-new.jsonl',
      hook_event_name: 'SessionStart',
      source: 'startup',
    });
  });

  it('warns the model before a file edit another thread holds, without deciding the permission', async () => {
    const beforeFileEdit = vi.fn(async (path: string) => path.endsWith('Composer.swift') ? 'Mateo is editing Composer.swift for 4 min.' : null);
    const canCallTool = vi.fn(async (): Promise<PermissionResult> => ({ behavior: 'deny', message: 'denied' }));
    const { hooks } = buildClaudeAgentSdkHooks({
      cwd: '/tmp/project',
      claudeConfigDir: null,
      getMode: () => ({ permissionMode: 'bypassPermissions' }),
      onSessionFound: () => {},
      onSessionHook: () => {},
      canCallTool,
      beforeFileEdit,
    });
    const preToolUse = hooks.PreToolUse as Array<{ matcher: string; hooks: Array<(input: unknown, id?: string, opts?: unknown) => Promise<any>> }>;
    const editHook = preToolUse.find((entry) => entry.matcher.split('|').includes('Edit'))!;
    expect(editHook.matcher.split('|').sort()).toEqual(['Edit', 'MultiEdit', 'NotebookEdit', 'Write']);

    const warned = await editHook.hooks[0]!({ hook_event_name: 'PreToolUse', tool_name: 'Edit', tool_input: { file_path: 'apps/Composer.swift' } });
    expect(beforeFileEdit).toHaveBeenCalledWith('/tmp/project/apps/Composer.swift');
    expect(warned.hookSpecificOutput).toEqual({
      hookEventName: 'PreToolUse',
      additionalContext: expect.stringContaining('Mateo is editing Composer.swift'),
    });
    expect(warned.hookSpecificOutput).not.toHaveProperty('permissionDecision');

    const quiet = await editHook.hooks[0]!({ tool_name: 'NotebookEdit', tool_input: { notebook_path: '/tmp/project/a.ipynb' } });
    expect(quiet).toEqual({ continue: true });
    expect(canCallTool).not.toHaveBeenCalled();
  });

  it('registers direct Runtime Activity hooks and forwards their exact inputs', async () => {
    const onSessionHook = vi.fn();
    const { hooks } = buildClaudeAgentSdkHooks({
      cwd: '/tmp/project',
      claudeConfigDir: null,
      getMode: makeMode,
      onSessionFound: () => {},
      onSessionHook,
      canCallTool: vi.fn(async (): Promise<PermissionResult> => ({ behavior: 'deny', message: 'denied' })),
    });

    for (const hookName of ['PostToolUse', 'SubagentStart', 'SubagentStop'] as const) {
      const registrations = hooks[hookName] as Array<{ hooks: Array<(input: unknown) => Promise<unknown>> }>;
      expect(registrations).toHaveLength(1);
      const input = { hook_event_name: hookName, session_id: 'session-1' };
      await registrations[0]!.hooks[0]!(input);
      expect(onSessionHook).toHaveBeenCalledWith(input);
    }
  });

  it('registers PermissionRequest and AskUserQuestion hooks so Claude Auto remains the permission authority', () => {
    const { hooks } = buildHooks();

    expect(hooks.PermissionRequest).toEqual([
      expect.objectContaining({ matcher: '*' }),
    ]);
    expect(hooks.PreToolUse).toEqual([
      expect.objectContaining({ matcher: 'AskUserQuestion' }),
    ]);
  });

  it('preserves permission metadata and provider updates through PermissionRequest hooks', async () => {
    const updatedInput = { file_path: '/tmp/file.txt' };
    const updatedPermissions = [{ type: 'setMode', mode: 'acceptEdits', destination: 'session' }];
    const suggestions = [{ type: 'setMode', mode: 'acceptEdits', destination: 'session' }];
    const canCallTool = vi.fn(async (): Promise<PermissionResult> => ({
      behavior: 'allow',
      updatedInput,
      updatedPermissions,
    }));
    const { hooks } = buildHooks(canCallTool);
    const signal = new AbortController().signal;
    const registrations = hooks.PermissionRequest as Array<{
      hooks: Array<(input: unknown, toolUseId: string, options: { signal: AbortSignal }) => Promise<unknown>>;
    }>;

    const output = await registrations[0]!.hooks[0]!({
      hook_event_name: 'PermissionRequest',
      tool_name: 'Read',
      tool_input: { file_path: '/tmp/input.txt' },
      permission_suggestions: suggestions,
      blocked_path: '/tmp/blocked.txt',
      decision_reason: 'requires approval',
      agent_id: 'agent_456',
    }, 'toolu_123', { signal });

    expect(canCallTool).toHaveBeenCalledWith(
      'Read',
      { file_path: '/tmp/input.txt' },
      expect.anything(),
      expect.objectContaining({
        signal,
        toolUseId: 'toolu_123',
        agentId: 'agent_456',
        suggestions,
        blockedPath: '/tmp/blocked.txt',
        decisionReason: 'requires approval',
      }),
    );
    expect(output).toEqual({
      continue: true,
      suppressOutput: true,
      hookSpecificOutput: {
        hookEventName: 'PermissionRequest',
        decision: { behavior: 'allow', updatedInput, updatedPermissions },
      },
    });
  });

  it('approves the original operation without marking unchanged arguments as a rewrite', async () => {
    const input = { command: 'git add --pathspec-from-file=paths.txt', description: 'Stage selected files' };
    const updatedPermissions = [{
      type: 'addRules', rules: [{ toolName: 'Bash', ruleContent: 'git add:*' }],
      behavior: 'allow', destination: 'session',
    }];
    const approvedInput = { ...input };
    // The permission coordinator normalizes JSON records to null-prototype objects.
    Object.setPrototypeOf(approvedInput, null);
    const { hooks } = buildClaudeAgentSdkHooks({
      cwd: '/tmp/project', claudeConfigDir: null, getMode: makeMode,
      onSessionFound: () => {}, onSessionHook: () => {},
      canCallTool: async () => ({ behavior: 'allow', updatedInput: approvedInput, updatedPermissions }),
    });
    const registrations = hooks.PermissionRequest as Array<{
      hooks: Array<(input: unknown, toolUseId: string, options: { signal: AbortSignal }) => Promise<unknown>>;
    }>;
    const output = await registrations[0]!.hooks[0]!({
      hook_event_name: 'PermissionRequest', tool_name: 'Bash', tool_input: input,
    }, 'toolu_original', { signal: new AbortController().signal });

    // Claude Code 2.1.280 rechecks any supplied updatedInput against ask rules before
    // applying updatedPermissions. An approval of the original input is not a rewrite.
    expect(output).toMatchObject({ hookSpecificOutput: {
      hookEventName: 'PermissionRequest', decision: { behavior: 'allow', updatedPermissions },
    } });
    expect(output).not.toHaveProperty('hookSpecificOutput.decision.updatedInput');
  });
});

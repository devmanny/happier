import { describe, expect, it, vi } from 'vitest';

import { executeClaimedRun, type ClaimableRunPayload } from './automationRunExecutor';

function claimed(payload: Record<string, unknown>): ClaimableRunPayload {
  return {
    run: {
      id: 'run-1', automationId: 'automation-1', state: 'queued', scheduledAt: 0, dueAt: 5_000, claimedAt: null, startedAt: null,
      finishedAt: null, claimedByMachineId: null, leaseExpiresAt: null, attempt: 1, summaryCiphertext: null, errorCode: null,
      errorMessage: null, producedSessionId: null, createdAt: 0, updatedAt: 0,
    },
    automation: {
      id: 'automation-1', name: 'task t1 rule r1', enabled: true, targetType: 'new_session',
      templateCiphertext: JSON.stringify({ kind: 'happier_automation_template_plain_v1', payload }),
    },
  };
}

function claimClient() {
  return {
    startRun: vi.fn(async () => {}),
    heartbeatRun: vi.fn(async () => {}),
    succeedRun: vi.fn(async () => {}),
    failRun: vi.fn(async () => {}),
  };
}

describe('executeClaimedRun (recurring task occurrences)', () => {
  const payload = { directory: '/repo', agent: 'claude', prompt: 'Recurring task', agentTaskV1: { taskId: 't1', ruleId: 'r1' } };

  it('hands a task rule\'s run to the task occurrence instead of spawning the template', async () => {
    const client = claimClient();
    const spawnSession = vi.fn();
    const runAgentTaskOccurrence = vi.fn(async () => ({ type: 'success' as const, sessionId: 's-new' }));
    await executeClaimedRun({
      token: 't', machineId: 'm1', claimClient: client, spawnSession, heartbeatMs: 60_000, leaseDurationMs: 120_000,
      claimed: claimed(payload), runAgentTaskOccurrence,
    });
    expect(runAgentTaskOccurrence).toHaveBeenCalledWith({ runId: 'run-1', dueAt: 5_000, taskId: 't1', ruleId: 'r1' });
    expect(spawnSession).not.toHaveBeenCalled();
    expect(client.succeedRun).toHaveBeenCalledWith({ runId: 'run-1', machineId: 'm1', producedSessionId: 's-new' });
  });

  it('fails the run with the occurrence\'s error, and when this daemon can\'t work tasks', async () => {
    const client = claimClient();
    await executeClaimedRun({
      token: 't', machineId: 'm1', claimClient: client, spawnSession: vi.fn(), heartbeatMs: 60_000, leaseDurationMs: 120_000,
      claimed: claimed(payload),
      runAgentTaskOccurrence: async () => ({ type: 'failed', errorCode: 'agent_profile_missing', errorMessage: 'gone' }),
    });
    expect(client.failRun).toHaveBeenLastCalledWith({ runId: 'run-1', machineId: 'm1', errorCode: 'agent_profile_missing', errorMessage: 'gone' });

    await executeClaimedRun({
      token: 't', machineId: 'm1', claimClient: client, spawnSession: vi.fn(), heartbeatMs: 60_000, leaseDurationMs: 120_000,
      claimed: claimed(payload),
    });
    expect(client.failRun).toHaveBeenLastCalledWith(expect.objectContaining({ errorCode: 'agent_task_unsupported' }));
  });
});

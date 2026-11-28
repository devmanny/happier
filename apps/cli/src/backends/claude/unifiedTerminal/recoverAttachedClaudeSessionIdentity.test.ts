import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { afterEach, describe, expect, it } from 'vitest';

import { recoverAttachedClaudeSessionIdentity, type ClaudeProcessProbe } from './recoverAttachedClaudeSessionIdentity';

describe('recoverAttachedClaudeSessionIdentity', () => {
  const tempDirs: string[] = [];

  afterEach(async () => {
    for (const dir of tempDirs.splice(0)) await rm(dir, { recursive: true, force: true });
  });

  async function fixture(record: Readonly<{ cwd: string; procStart: string }>, liveStart: string) {
    const dir = await mkdtemp(join(tmpdir(), 'happier-claude-process-record-'));
    tempDirs.push(dir);
    const workspaceDir = join(dir, 'workspace');
    const otherWorkspaceDir = join(dir, 'other');
    await mkdir(workspaceDir, { recursive: true });
    await mkdir(otherWorkspaceDir, { recursive: true });
    const claudeConfigDir = join(dir, 'claude-config');
    await mkdir(join(claudeConfigDir, 'sessions'), { recursive: true });
    await writeFile(join(claudeConfigDir, 'sessions', '20.json'), JSON.stringify({
      pid: 20,
      sessionId: 'claude-session-a',
      cwd: record.cwd === 'other' ? otherWorkspaceDir : workspaceDir,
      procStart: record.procStart,
    }));
    const probe: ClaudeProcessProbe = {
      listProcesses: async () => [{ pid: 10, ppid: 1 }, { pid: 20, ppid: 10 }],
      readProcessStartUtc: async () => liveStart,
    };
    return recoverAttachedClaudeSessionIdentity({ hostRootPid: 10, claudeConfigDir, workingDirectory: workspaceDir, probe });
  }

  it('rejects a record whose pid now belongs to a process started at another time', async () => {
    await expect(fixture({ cwd: 'same', procStart: 'Mon Nov 16 21:51:45 2026' }, 'Tue Nov 17 13:45:05 2026'))
      .resolves.toEqual({ status: 'unavailable', reason: 'process_start_mismatch' });
  });

  it('rejects a record for a Claude running in another project', async () => {
    await expect(fixture({ cwd: 'other', procStart: 'Mon Nov 16 21:51:45 2026' }, 'Mon Nov 16 21:51:45 2026'))
      .resolves.toEqual({ status: 'unavailable', reason: 'cwd_mismatch' });
  });
});

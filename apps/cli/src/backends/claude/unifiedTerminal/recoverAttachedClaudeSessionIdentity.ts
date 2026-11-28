import { execFile } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';

import { listProcessSnapshot } from '@/daemon/processSnapshotCache';
import { getProjectPath, resolveClaudeProjectId } from '../utils/path';

/**
 * OS process boundary used to tie a Claude process record to the live Claude in an adopted host.
 * `readProcessStartUtc` returns the kernel start time in `ps -o lstart` form rendered in UTC, the
 * same form Claude writes as `procStart`, or null when it cannot be read.
 */
export type ClaudeProcessProbe = Readonly<{
  listProcesses: () => Promise<readonly Readonly<{ pid: number; ppid?: number }>[]>;
  readProcessStartUtc: (pid: number) => Promise<string | null>;
}>;

export type AttachedClaudeSessionIdentity = Readonly<{
  sessionId: string;
  transcriptPath: string;
  claudePid: number;
}>;

export type AttachedClaudeSessionIdentityRecovery =
  | Readonly<{ status: 'recovered'; identity: AttachedClaudeSessionIdentity }>
  | Readonly<{ status: 'unavailable'; reason: string }>;

function readProcessStartUtcWithPs(pid: number): Promise<string | null> {
  return new Promise((resolve) => {
    execFile('ps', ['-o', 'lstart=', '-p', String(pid)], {
      encoding: 'utf8',
      windowsHide: true,
      env: { ...process.env, TZ: 'UTC', LC_ALL: 'C', LANG: 'C' },
    }, (error, stdout) => {
      const value = error ? '' : String(stdout).trim();
      resolve(value || null);
    });
  });
}

export const defaultClaudeProcessProbe: ClaudeProcessProbe = {
  listProcesses: () => listProcessSnapshot(),
  readProcessStartUtc: readProcessStartUtcWithPs,
};

function normalizeProcessStart(value: string): string {
  return value.trim().replace(/\s+/g, ' ');
}

function collectProcessTree(rootPid: number, processes: readonly Readonly<{ pid: number; ppid?: number }>[]): number[] {
  const childrenByParent = new Map<number, number[]>();
  for (const entry of processes) {
    if (typeof entry.ppid !== 'number') continue;
    const children = childrenByParent.get(entry.ppid) ?? [];
    children.push(entry.pid);
    childrenByParent.set(entry.ppid, children);
  }
  const tree: number[] = [];
  const queue = [rootPid];
  const seen = new Set<number>();
  while (queue.length > 0) {
    const pid = queue.shift() as number;
    if (seen.has(pid)) continue;
    seen.add(pid);
    tree.push(pid);
    queue.push(...(childrenByParent.get(pid) ?? []));
  }
  return tree;
}

type ClaudeProcessRecord = Readonly<{ pid: number; sessionId: string; cwd: string; procStart: string }>;

async function readClaudeProcessRecord(claudeConfigDir: string, pid: number): Promise<ClaudeProcessRecord | null> {
  let raw: string;
  try {
    raw = await readFile(join(claudeConfigDir, 'sessions', `${pid}.json`), 'utf8');
  } catch {
    return null;
  }
  try {
    const value: unknown = JSON.parse(raw);
    if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
    const record = value as Record<string, unknown>;
    const sessionId = typeof record.sessionId === 'string' ? record.sessionId.trim() : '';
    const cwd = typeof record.cwd === 'string' ? record.cwd : '';
    const procStart = typeof record.procStart === 'string' ? record.procStart : '';
    if (record.pid !== pid || !sessionId || !cwd || !procStart) return null;
    return { pid, sessionId, cwd, procStart };
  } catch {
    return null;
  }
}

/**
 * Recovers the conversation id of the live Claude running under an adopted terminal host from
 * Claude's own process record (`<CLAUDE_CONFIG_DIR>/sessions/<pid>.json`). The record must belong
 * to a process inside the host's process tree, whose live start time matches the record and whose
 * cwd maps to this session's Claude project. The id still has to pass the session identity owner's
 * transcript proof before it is published.
 */
export async function recoverAttachedClaudeSessionIdentity(params: Readonly<{
  hostRootPid: number;
  claudeConfigDir: string;
  workingDirectory: string;
  probe: ClaudeProcessProbe;
}>): Promise<AttachedClaudeSessionIdentityRecovery> {
  let processes: readonly Readonly<{ pid: number; ppid?: number }>[];
  try {
    processes = await params.probe.listProcesses();
  } catch {
    return { status: 'unavailable', reason: 'process_list_unavailable' };
  }
  const candidates: ClaudeProcessRecord[] = [];
  for (const pid of collectProcessTree(params.hostRootPid, processes)) {
    const record = await readClaudeProcessRecord(params.claudeConfigDir, pid);
    if (record) candidates.push(record);
  }
  if (candidates.length === 0) return { status: 'unavailable', reason: 'no_process_record' };
  if (candidates.length > 1) return { status: 'unavailable', reason: 'ambiguous_process_records' };
  const record = candidates[0] as ClaudeProcessRecord;

  const liveStart = await params.probe.readProcessStartUtc(record.pid).catch(() => null);
  if (!liveStart || normalizeProcessStart(liveStart) !== normalizeProcessStart(record.procStart)) {
    return { status: 'unavailable', reason: 'process_start_mismatch' };
  }
  if (resolveClaudeProjectId(record.cwd) !== resolveClaudeProjectId(params.workingDirectory)) {
    return { status: 'unavailable', reason: 'cwd_mismatch' };
  }
  return {
    status: 'recovered',
    identity: {
      sessionId: record.sessionId,
      transcriptPath: join(getProjectPath(params.workingDirectory, params.claudeConfigDir), `${record.sessionId}.jsonl`),
      claudePid: record.pid,
    },
  };
}

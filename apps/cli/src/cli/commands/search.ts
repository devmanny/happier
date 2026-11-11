import { rm, stat } from 'node:fs/promises';
import { createInterface } from 'node:readline/promises';

import {
  applyMessageSearchSwitch,
  isMessageSearchEnabled,
  messageSearchProgress,
  type MessageSearchSetRequestV1,
  type MessageSearchStatusV1,
} from '@happier-dev/protocol';

import type { CommandContext } from '@/cli/commandRegistry';
import { requestDaemonMessageSearchSet, requestDaemonMessageSearchStatus } from '@/daemon/controlClient';
import { resolveMemoryIndexPaths } from '@/daemon/memory/memoryIndexPaths';
import { readMemorySettingsFromDisk, writeMemorySettingsToDisk } from '@/settings/memorySettings';

/**
 * `happier search enable|disable|status`: conversation search on this machine (the full-text
 * index its daemon keeps and answers searches from). A running daemon switches it itself, so it
 * closes the index before deleting it; without one, the machine settings are written for its
 * next start.
 */
export type SearchCommandDeps = Readonly<{
  daemonStatus: () => Promise<MessageSearchStatusV1 | null>;
  daemonSet: (request: MessageSearchSetRequestV1) => Promise<MessageSearchStatusV1 | null>;
  confirm: (question: string) => Promise<boolean>;
  print: (line: string) => void;
}>;

const USAGE = 'Usage: happier search enable|disable|status [--delete-index] [--yes] [--json]';

async function confirmOnTerminal(question: string): Promise<boolean> {
  if (!process.stdin.isTTY) return false;
  const prompt = createInterface({ input: process.stdin, output: process.stdout });
  try {
    return /^(y|yes|s|si|sí)$/iu.test((await prompt.question(`${question} [y/N] `)).trim());
  } finally {
    prompt.close();
  }
}

const DEFAULT_DEPS: SearchCommandDeps = {
  daemonStatus: requestDaemonMessageSearchStatus,
  daemonSet: requestDaemonMessageSearchSet,
  confirm: confirmOnTerminal,
  print: (line) => console.log(line),
};

function formatBytes(bytes: number | null): string {
  if (bytes === null) return 'no index';
  if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

async function readLocalIndexBytes(): Promise<number | null> {
  const { deepDbPath } = resolveMemoryIndexPaths();
  let total: number | null = null;
  for (const path of [deepDbPath, `${deepDbPath}-wal`]) {
    const size = await stat(path).then((s) => s.size, () => null);
    if (size !== null) total = (total ?? 0) + size;
  }
  return total;
}

/** What the machine settings alone say, while no daemon runs. */
async function readOfflineStatus(): Promise<MessageSearchStatusV1> {
  const enabled = isMessageSearchEnabled(await readMemorySettingsFromDisk());
  return { v: 1, enabled, state: enabled ? 'indexing' : 'off', coverage: null, indexBytes: await readLocalIndexBytes() };
}

function describe(status: MessageSearchStatusV1, daemonRunning: boolean): string {
  const size = formatBytes(status.indexBytes);
  if (!status.enabled) return `Conversation search: off (${size}).`;
  if (!daemonRunning) return `Conversation search: on; the daemon isn't running (${size}).`;
  const coverage = status.coverage;
  if (status.state === 'ready') {
    return `Conversation search: ready, ${coverage?.messageCount ?? 0} messages from ${coverage?.sessionCount ?? 0} sessions (${size}).`;
  }
  const percent = Math.floor(messageSearchProgress(coverage) * 100);
  return `Conversation search: indexing ${percent}% (${coverage?.pendingSessionCount ?? 0} of ${coverage?.knownSessionCount ?? 0} sessions left, ${size}).`;
}

export async function runSearchCommand(args: readonly string[], deps: SearchCommandDeps = DEFAULT_DEPS): Promise<number> {
  const [subcommand, ...rest] = args;
  const json = rest.includes('--json');
  const deleteIndex = rest.includes('--delete-index');
  const assumeYes = rest.includes('--yes');
  const unknown = rest.filter((arg) => !['--json', '--delete-index', '--yes'].includes(arg));
  if (!subcommand || !['enable', 'disable', 'status'].includes(subcommand) || unknown.length > 0
    || (deleteIndex && subcommand !== 'disable')) {
    deps.print(USAGE);
    return 1;
  }

  const report = (status: MessageSearchStatusV1, daemonRunning: boolean, extra?: string) => {
    if (json) {
      deps.print(JSON.stringify({ ...status, progress: messageSearchProgress(status.coverage), daemon: daemonRunning ? 'running' : 'not_running' }, null, 2));
      return;
    }
    deps.print(describe(status, daemonRunning));
    if (extra) deps.print(extra);
  };

  if (subcommand === 'status') {
    const live = await deps.daemonStatus();
    report(live ?? await readOfflineStatus(), live !== null);
    return 0;
  }

  const enabled = subcommand === 'enable';
  if (deleteIndex && !assumeYes) {
    const size = formatBytes(await readLocalIndexBytes());
    if (!await deps.confirm(`Delete this machine's conversation index (${size})? Searching again means reading every conversation again.`)) {
      deps.print('Nothing changed.');
      return 1;
    }
  }

  const request: MessageSearchSetRequestV1 = { v: 1, enabled, deleteIndex };
  const live = await deps.daemonSet(request);
  if (live) {
    report(live, true, !enabled && !deleteIndex && live.indexBytes !== null ? 'The index is kept; `happier search disable --delete-index` removes it.' : undefined);
    return 0;
  }

  // No daemon: the machine settings decide what it does when it starts.
  await writeMemorySettingsToDisk(applyMessageSearchSwitch(await readMemorySettingsFromDisk(), enabled));
  if (deleteIndex) await rm(resolveMemoryIndexPaths().memoryDir, { recursive: true, force: true });
  const status = await readOfflineStatus();
  report(status, false, enabled
    ? 'It starts indexing when the daemon starts.'
    : status.indexBytes !== null ? 'The index is kept; `happier search disable --delete-index` removes it.' : undefined);
  return 0;
}

export async function handleSearchCliCommand(context: CommandContext): Promise<void> {
  process.exitCode = await runSearchCommand(context.args.slice(1));
}

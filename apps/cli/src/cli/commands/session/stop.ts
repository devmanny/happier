import chalk from 'chalk';

import type { Credentials } from '@/persistence';
import { hasFlag, readCommandPositionals, readFlagValue } from '@/cli/commands/shared/argvFlags';
import { wantsJson, printJsonEnvelope } from '@/cli/output/jsonEnvelope';
import { createCliActionExecutorFromCredentials } from '@/session/actions/createCliActionExecutorFromCredentials';
import { normalizeActionExecuteResult } from './shared/normalizeActionExecuteResult';
import { tryHandleApprovalRequestCreated } from './shared/tryHandleApprovalRequestCreated';
import { cmd, fail } from '@happier-dev/cli-common/output';

export async function cmdSessionStop(
  argv: string[],
  deps: Readonly<{ readCredentialsFn: () => Promise<Credentials | null> }>,
): Promise<void> {
  const json = wantsJson(argv);
  const [idOrPrefix = ''] = readCommandPositionals(argv, { startIndex: 1, valueFlags: ['--reason'] });
  // An automatic stop names its reason; the action input accepts only the closed set (`idle`).
  const reason = readFlagValue(argv, '--reason');
  if (!idOrPrefix || (hasFlag(argv, '--reason') && !reason)) {
    throw new Error('Usage: happier session stop <session-id-or-prefix> [--reason idle] [--json]');
  }

  const credentials = await deps.readCredentialsFn();
  if (!credentials) {
    if (json) {
      await printJsonEnvelope({ ok: false, kind: 'session_stop', error: { code: 'not_authenticated' } });
      return;
    }
    console.error(fail(`Not signed in. Run ${cmd('happier auth login')} first.`));
    process.exit(1);
  }

  const executor = createCliActionExecutorFromCredentials({ credentials });
  const actionRes = await executor.execute(
    'session.stop',
    { sessionId: idOrPrefix, ...(reason ? { reason } : {}) },
    { surface: 'cli', defaultSessionId: null },
  );
  const normalized = normalizeActionExecuteResult(actionRes as any);
  if (!normalized.ok) {
    if (json) {
      await printJsonEnvelope({
        ok: false,
        kind: 'session_stop',
        error: { code: normalized.errorCode, ...(normalized.candidates ? { candidates: normalized.candidates } : {}), ...(normalized.errorMessage ? { message: normalized.errorMessage } : {}) },
      });
      return;
    }
    throw new Error(normalized.errorCode);
  }

  const result = normalized.data as any;
  if (await tryHandleApprovalRequestCreated({ envelopeKind: 'session_stop', json, result })) {
    return;
  }
  if (json) {
    await printJsonEnvelope({
      ok: true,
      kind: 'session_stop',
      data: {
        sessionId: result.sessionId,
        stopped: result.stopped,
        ...(result.stopOutcome ? { stopOutcome: result.stopOutcome } : {}),
        ...(result.sessionRest ? { sessionRest: result.sessionRest } : {}),
        ...(result.sessionRestError ? { sessionRestError: result.sessionRestError } : {}),
      },
    });
    return;
  }

  if (result.sessionRestError) {
    console.log(chalk.yellow('!'), `session could not be marked as resting (${result.sessionRestError})`);
  }

  if (result.stopped) {
    console.log(chalk.green('✓'), result.sessionRest ? 'session stopped; resting' : 'session stopped');
    return;
  }

  // A confirmed stop with nothing to signal. Before the stop owner could name
  // this state it fell through to "stop could not be confirmed", which told the
  // user an already-stopped Session was indeterminate.
  if (result.stopOutcome?.status === 'already_stopped') {
    console.log(chalk.green('✓'), result.sessionRest ? 'session already stopped; resting' : 'session already stopped');
    return;
  }

  if (result.stopOutcome?.status === 'stopped_projection_unconfirmed') {
    console.log(chalk.yellow('!'), 'session stopped; status update not yet observed');
    return;
  }

  if (result.stopOutcome?.status === 'stopped_cleanup_incomplete') {
    console.log(chalk.yellow('!'), 'session stopped; local cleanup could not be completed');
    return;
  }

  console.log(chalk.yellow('!'), 'stop could not be confirmed');
}

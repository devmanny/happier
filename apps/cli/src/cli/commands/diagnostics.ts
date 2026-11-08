import chalk from 'chalk';

import { fail } from '@happier-dev/cli-common/output';

import { createAccountKvHttpTransport } from '@/api/kv/accountKvHttpTransport';
import type { CommandContext } from '@/cli/commandRegistry';
import { configuration } from '@/configuration';
import { readCredentials, resolveAccountScopedCryptoMaterial } from '@/persistence';

import { parseDiagnosticsPullArgs } from './diagnostics/parseDiagnosticsArgs';
import { pullDeviceDiagnostics } from './diagnostics/pullDeviceDiagnostics';

const HELP = `
${chalk.bold('happier diagnostics')} - Reports the Happier Apple app saved for you (MetricKit crashes, hangs, metrics)

${chalk.bold('Usage:')}
  happier diagnostics pull [--out <dir>] [--keep] [--json]

${chalk.bold('Options:')}
  --out <dir>   Folder for the reports (default: ~/.happier/diagnostics)
  --keep        Leave the reports in your account after saving them
  --json        Print a JSON summary
`;

export async function handleDiagnosticsCliCommand(context: CommandContext): Promise<void> {
  const [subcommand, ...rest] = context.args.slice(1);
  if (!subcommand || subcommand === '--help' || subcommand === '-h' || subcommand === 'help') {
    console.log(HELP);
    return;
  }
  try {
    if (subcommand !== 'pull') throw new Error(`Unknown diagnostics command: ${subcommand}`);
    const args = parseDiagnosticsPullArgs(rest, { happyHomeDir: configuration.happyHomeDir, env: process.env });
    const credentials = await readCredentials();
    if (!credentials) throw new Error('Not signed in. Run "happier auth login" first.');
    const summary = await pullDeviceDiagnostics({
      transport: createAccountKvHttpTransport({ token: credentials.token }),
      material: resolveAccountScopedCryptoMaterial(credentials),
      outDir: args.outDir,
      keep: args.keep,
    });
    if (args.json) {
      console.log(JSON.stringify(summary, null, 2));
    } else {
      for (const entry of summary.pulled) console.log(`${entry.tooLarge ? 'too large (summary only)' : 'saved'}  ${entry.file}`);
      for (const entry of summary.failed) console.error(fail(`${entry.key}: ${entry.error}`));
      console.log(`${summary.pulled.length} report(s) in ${summary.outDir}${args.keep ? ' (kept in your account)' : ''}`);
      if (!summary.complete) console.log(chalk.yellow('More reports remain than one listing holds; run it again.'));
    }
    if (summary.failed.length > 0) process.exitCode = 1;
  } catch (error) {
    console.error(fail(error instanceof Error ? error.message : String(error)));
    process.exit(1);
  }
}

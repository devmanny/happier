import { join, resolve } from 'node:path';

import { expandHomeDirPath } from '@/utils/path/expandHomeDirPath';

export type DiagnosticsPullArgs = Readonly<{ outDir: string; keep: boolean; json: boolean }>;

/** `happier diagnostics pull [--out <dir>] [--keep] [--json]`; the default folder is `<happier home>/diagnostics`. */
export function parseDiagnosticsPullArgs(
  args: readonly string[],
  context: Readonly<{ happyHomeDir: string; env: NodeJS.ProcessEnv }>,
): DiagnosticsPullArgs {
  let outDir = join(context.happyHomeDir, 'diagnostics');
  let keep = false;
  let json = false;
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--keep') keep = true;
    else if (arg === '--json') json = true;
    else if (arg === '--out') {
      const value = args[index + 1];
      if (!value || value.startsWith('--')) throw new Error('--out needs a folder');
      outDir = resolve(expandHomeDirPath(value, context.env));
      index += 1;
    } else {
      throw new Error(`Unknown argument for diagnostics pull: ${arg}`);
    }
  }
  return { outDir, keep, json };
}

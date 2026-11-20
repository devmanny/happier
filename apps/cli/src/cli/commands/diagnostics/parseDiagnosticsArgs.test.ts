import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

import { parseDiagnosticsPullArgs } from './parseDiagnosticsArgs';

describe('parseDiagnosticsPullArgs', () => {
  const home = '/home/manny/.happier';
  const env = { HOME: '/home/manny' } as NodeJS.ProcessEnv;

  it('defaults to the diagnostics folder in the Happier home, deleting what it pulls', () => {
    expect(parseDiagnosticsPullArgs([], { happyHomeDir: home, env })).toEqual({ outDir: join(home, 'diagnostics'), keep: false, json: false });
  });

  it('reads --out (home-relative), --keep and --json, and rejects anything else', () => {
    expect(parseDiagnosticsPullArgs(['--out', '~/reports', '--keep', '--json'], { happyHomeDir: home, env }))
      .toEqual({ outDir: join('/home/manny', 'reports'), keep: true, json: true });
    expect(() => parseDiagnosticsPullArgs(['--out'], { happyHomeDir: home, env })).toThrow('--out');
    expect(() => parseDiagnosticsPullArgs(['--force'], { happyHomeDir: home, env })).toThrow('--force');
  });
});

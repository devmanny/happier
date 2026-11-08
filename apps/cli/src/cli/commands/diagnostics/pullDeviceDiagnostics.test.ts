import { mkdtemp, readdir, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { deflateRawSync } from 'node:zlib';

import { afterEach, beforeEach, describe, expect, it } from 'vitest';

import { sealAccountScopedBlobCiphertext, type AccountScopedCryptoMaterial } from '@happier-dev/protocol';

import { createInMemoryAccountKv } from '@/api/kv/inMemoryAccountKv.testkit';

import { pullDeviceDiagnostics } from './pullDeviceDiagnostics';

const material: AccountScopedCryptoMaterial = { type: 'dataKey', machineKey: new Uint8Array(32).fill(4) };
const createdAt = Date.UTC(2026, 10, 8, 9, 30, 0);
/** `NSData.compressed(using: .zlib)` on macOS 26 of `{"hello":"metrickit","n":[1,2,3,1,2,3,1,2,3]}`. */
const APPLE_ZLIB = 'q1bKSM3JyVeyUspNLSnKTM7OLFHSUcpTsoo21DHSMdZBImNrAQ==';

function seal(payload: unknown): string {
  return sealAccountScopedBlobCiphertext({ kind: 'device_diagnostics', material, payload, randomBytes: (n) => new Uint8Array(n).fill(1) });
}

function payloadEntry(kind: 'diagnostic' | 'metric', payloadBase64: string) {
  return { v: 1, kind, createdAt, device: { model: 'iPhone17,1', os: 'iOS 26.1' }, appVersion: '0.2.19', build: '412', encoding: 'zlib', payloadBase64 };
}

describe('pullDeviceDiagnostics', () => {
  let out: string;
  beforeEach(async () => { out = await mkdtemp(join(tmpdir(), 'happier-diag-')); });
  afterEach(async () => { await rm(out, { recursive: true, force: true }); });

  it('writes each report decompressed to its own file, then deletes its key', async () => {
    const kv = createInMemoryAccountKv();
    kv.rows.set('diag/a1', { value: seal(payloadEntry('diagnostic', APPLE_ZLIB)), version: 0 });
    kv.rows.set('diag/b2', { value: seal({ v: 1, kind: 'metric', tooLarge: true, compressedBytes: 200_000_000, rawBytes: 900_000_000, build: '412', createdAt }), version: 3 });
    kv.rows.set('task/t1', { value: 'not a diagnostic', version: 0 });

    const summary = await pullDeviceDiagnostics({ transport: kv.transport, material, outDir: out, keep: false });

    expect(summary.failed).toEqual([]);
    expect(summary.complete).toBe(true);
    expect(summary.pulled.map((entry) => entry.key)).toEqual(['diag/a1', 'diag/b2']);
    const files = (await readdir(out)).sort();
    expect(files).toEqual(['2026-11-08T09-30-00.000Z-diagnostic-412-a1.json', '2026-11-08T09-30-00.000Z-metric-412-b2.json']);
    const report = JSON.parse(await readFile(join(out, files[0]!), 'utf8'));
    expect(report.payload).toEqual({ hello: 'metrickit', n: [1, 2, 3, 1, 2, 3, 1, 2, 3] });
    expect(report).toMatchObject({ key: 'diag/a1', kind: 'diagnostic', build: '412', device: { model: 'iPhone17,1' } });
    expect(JSON.parse(await readFile(join(out, files[1]!), 'utf8'))).toMatchObject({ tooLarge: true, rawBytes: 900_000_000 });
    // Deleted at their versions; other keys untouched.
    expect(kv.rows.get('diag/a1')).toEqual({ value: null, version: 1 });
    expect(kv.rows.get('diag/b2')).toEqual({ value: null, version: 4 });
    expect(kv.rows.get('task/t1')?.value).toBe('not a diagnostic');
  });

  it('keeps the keys with keep', async () => {
    const kv = createInMemoryAccountKv();
    kv.rows.set('diag/a1', { value: seal(payloadEntry('metric', deflateRawSync('{"x":1}').toString('base64'))), version: 0 });
    const summary = await pullDeviceDiagnostics({ transport: kv.transport, material, outDir: out, keep: true });
    expect(summary.pulled).toHaveLength(1);
    expect(kv.rows.get('diag/a1')?.version).toBe(0);
  });

  it('reports an entry it cannot read or write and leaves its key in place', async () => {
    const kv = createInMemoryAccountKv();
    kv.rows.set('diag/bad', { value: 'AAAA', version: 0 });
    kv.rows.set('diag/notjson', { value: seal(payloadEntry('metric', deflateRawSync('nope').toString('base64'))), version: 0 });
    const summary = await pullDeviceDiagnostics({ transport: kv.transport, material, outDir: join(out, 'nested'), keep: false });
    expect(summary.pulled).toEqual([]);
    expect(summary.failed.map((entry) => entry.key)).toEqual(['diag/bad', 'diag/notjson']);
    expect(kv.rows.get('diag/bad')?.value).toBe('AAAA');
    expect(kv.rows.get('diag/notjson')?.version).toBe(0);
  });

  it('lists again past one full listing, and says when a listing it cannot drain was full', async () => {
    const kv = createInMemoryAccountKv();
    const value = seal(payloadEntry('metric', deflateRawSync('{}').toString('base64')));
    for (let i = 0; i < 1001; i += 1) kv.rows.set(`diag/${String(i).padStart(4, '0')}`, { value, version: 0 });

    const kept = await pullDeviceDiagnostics({ transport: kv.transport, material, outDir: out, keep: true });
    expect(kept.pulled).toHaveLength(1000);
    expect(kept.complete).toBe(false);

    const drained = await pullDeviceDiagnostics({ transport: kv.transport, material, outDir: out, keep: false });
    expect(drained.pulled).toHaveLength(1001);
    expect(drained.complete).toBe(true);
    expect([...kv.rows.values()].every((row) => row.value === null)).toBe(true);
  });
});

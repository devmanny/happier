import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { inflateRawSync } from 'node:zlib';

import {
  DEVICE_DIAGNOSTICS_KV_PREFIX,
  openAccountScopedBlobCiphertext,
  parseDeviceDiagnosticV1,
  type AccountScopedCryptoMaterial,
  type DeviceDiagnosticV1,
} from '@happier-dev/protocol';

import { ACCOUNT_KV_LIST_MAX_ROWS, type AccountKvTransport } from '@/api/kv/accountKvHttpTransport';

export type PulledDeviceDiagnostic = Readonly<{
  key: string;
  file: string;
  kind: DeviceDiagnosticV1['kind'];
  build: string;
  tooLarge: boolean;
  deleted: boolean;
}>;

export type DeviceDiagnosticsPullSummary = Readonly<{
  outDir: string;
  pulled: PulledDeviceDiagnostic[];
  failed: Array<Readonly<{ key: string; error: string }>>;
  /** False when a listing came back full and its remaining rows couldn't be reached (`--keep`, or failures). */
  complete: boolean;
}>;

/**
 * The native app's MetricKit reports (`diag/<uuid>`, kind `device_diagnostics`): each one is written
 * to `<outDir>/<createdAt>-<kind>-<build>-<uuid>.json` and, unless `keep`, deleted at its version
 * only once its file was written. An entry that can't be read or written is reported and kept.
 */
export async function pullDeviceDiagnostics(params: Readonly<{
  transport: AccountKvTransport;
  material: AccountScopedCryptoMaterial;
  outDir: string;
  keep: boolean;
}>): Promise<DeviceDiagnosticsPullSummary> {
  await mkdir(params.outDir, { recursive: true });
  const pulled: PulledDeviceDiagnostic[] = [];
  const failed: Array<{ key: string; error: string }> = [];
  const seen = new Set<string>();
  // `GET /v1/kv` has no cursor: deleted rows leave the listing, so listing again reaches the rest.
  // A pass that finds nothing new (kept or failed rows fill it) stops.
  while (true) {
    const rows = await params.transport.list(DEVICE_DIAGNOSTICS_KV_PREFIX);
    const fresh = rows.filter((row) => !seen.has(row.key));
    for (const row of fresh) {
      seen.add(row.key);
      try {
        pulled.push(await pullOne(row, params));
      } catch (error) {
        failed.push({ key: row.key, error: error instanceof Error ? error.message : String(error) });
      }
    }
    const full = rows.length >= ACCOUNT_KV_LIST_MAX_ROWS;
    if (!full) return { outDir: params.outDir, pulled, failed, complete: true };
    if (params.keep || fresh.length === 0) return { outDir: params.outDir, pulled, failed, complete: false };
  }
}

async function pullOne(
  row: Readonly<{ key: string; value: string; version: number }>,
  params: Readonly<{ transport: AccountKvTransport; material: AccountScopedCryptoMaterial; outDir: string; keep: boolean }>,
): Promise<PulledDeviceDiagnostic> {
  const opened = openAccountScopedBlobCiphertext({ kind: 'device_diagnostics', material: params.material, ciphertext: row.value });
  const record = opened ? parseDeviceDiagnosticV1(opened.value) : null;
  if (!record) throw new Error('not a readable device diagnostic for this account');

  const id = row.key.slice(DEVICE_DIAGNOSTICS_KV_PREFIX.length);
  const file = join(params.outDir, `${fileStamp(record.createdAt)}-${record.kind}-${fileSafe(record.build)}-${fileSafe(id)}.json`);
  const document = 'tooLarge' in record ? { key: row.key, ...record } : documentFor(row.key, record);
  await writeFile(file, `${JSON.stringify(document, null, 2)}\n`, 'utf8');

  let deleted = false;
  if (!params.keep) {
    const result = await params.transport.mutate([{ key: row.key, value: null, version: row.version }]);
    if (!result.ok) throw new Error(`saved to ${file}, but the key changed before it could be deleted`);
    deleted = true;
  }
  return { key: row.key, file, kind: record.kind, build: record.build, tooLarge: 'tooLarge' in record, deleted };
}

function documentFor(key: string, record: Extract<DeviceDiagnosticV1, { payloadBase64: string }>) {
  if (record.encoding !== 'zlib') throw new Error(`${record.encoding} payloads can't be decompressed here`);
  const { payloadBase64, encoding: _encoding, ...meta } = record;
  const json = inflateRawSync(Buffer.from(payloadBase64, 'base64')).toString('utf8');
  let payload: unknown;
  try {
    payload = JSON.parse(json);
  } catch {
    throw new Error('the decompressed payload is not JSON');
  }
  return { key, ...meta, payload };
}

/** An ISO time without `:` (not allowed in Windows file names). */
function fileStamp(createdAt: number): string {
  return new Date(createdAt).toISOString().replaceAll(':', '-');
}

function fileSafe(part: string): string {
  return part.replace(/[^A-Za-z0-9._-]/gu, '_') || '_';
}

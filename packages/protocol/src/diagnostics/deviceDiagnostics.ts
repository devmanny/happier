import { z } from 'zod';

/**
 * MetricKit reports (crashes, hangs, daily metrics) the native Apple app saves for the developer in
 * the account's own UserKVStore, one per key `diag/<uuid>`, sealed with kind `device_diagnostics`.
 * `happier diagnostics pull` writes them to files and deletes them.
 *
 * A report whose write would exceed the relay's request body limit is saved as a short `tooLarge`
 * entry instead, so it is never lost silently.
 */
export const DEVICE_DIAGNOSTICS_KV_PREFIX = 'diag/';

const KindSchema = z.enum(['diagnostic', 'metric']);

const DeviceDiagnosticPayloadV1Schema = z.object({
  v: z.literal(1),
  kind: KindSchema,
  createdAt: z.number(),
  device: z.object({ model: z.string(), os: z.string() }),
  appVersion: z.string(),
  build: z.string(),
  /** Apple's `NSData.compressed(using: .zlib)`: raw DEFLATE (RFC 1951), without a zlib header. */
  encoding: z.enum(['zlib', 'lzfse']),
  payloadBase64: z.string(),
});

const DeviceDiagnosticTooLargeV1Schema = z.object({
  v: z.literal(1),
  kind: KindSchema,
  tooLarge: z.literal(true),
  compressedBytes: z.number(),
  rawBytes: z.number(),
  build: z.string(),
  createdAt: z.number(),
});

export const DeviceDiagnosticV1Schema = z.union([DeviceDiagnosticTooLargeV1Schema, DeviceDiagnosticPayloadV1Schema]);
export type DeviceDiagnosticV1 = z.infer<typeof DeviceDiagnosticV1Schema>;

export function parseDeviceDiagnosticV1(value: unknown): DeviceDiagnosticV1 | null {
  const parsed = DeviceDiagnosticV1Schema.safeParse(value);
  return parsed.success ? parsed.data : null;
}

import { describe, expect, it } from 'vitest';

import { decodeBase64 } from '../crypto/base64.js';
import { openAccountScopedBlobCiphertext, sealAccountScopedBlobCiphertext } from '../crypto/accountScopedCipher.js';
import { DEVICE_DIAGNOSTICS_KV_PREFIX, parseDeviceDiagnosticV1 } from './deviceDiagnostics.js';

const material = { type: 'dataKey', machineKey: new Uint8Array(32).fill(3) } as const;
const randomBytes = (length: number) => new Uint8Array(length).fill(9);

describe('device diagnostics records', () => {
  it('seals under their own kind byte (15), unreadable as any other kind', () => {
    const payload = { v: 1, kind: 'metric', createdAt: 1, device: { model: 'iPhone17,1', os: 'iOS 26.1' },
      appVersion: '0.2.19', build: '412', encoding: 'zlib', payloadBase64: 'eJw=' };
    const ciphertext = sealAccountScopedBlobCiphertext({ kind: 'device_diagnostics', material, payload, randomBytes });
    expect(decodeBase64(ciphertext, 'base64')[1]).toBe(15);
    expect(openAccountScopedBlobCiphertext({ kind: 'device_diagnostics', material, ciphertext })?.value).toEqual(payload);
    expect(openAccountScopedBlobCiphertext({ kind: 'agent_task', material, ciphertext })).toBeNull();
  });

  it('reads a payload entry and a too-large entry, and nothing else', () => {
    expect(DEVICE_DIAGNOSTICS_KV_PREFIX).toBe('diag/');
    expect(parseDeviceDiagnosticV1({ v: 1, kind: 'diagnostic', createdAt: 5, device: { model: 'Mac16,1', os: 'macOS 26.1' },
      appVersion: '0.2.19', build: '7', encoding: 'zlib', payloadBase64: 'AA==' })?.kind).toBe('diagnostic');
    expect(parseDeviceDiagnosticV1({ v: 1, kind: 'metric', tooLarge: true, compressedBytes: 9, rawBytes: 20, build: '7', createdAt: 5 }))
      .toMatchObject({ tooLarge: true, rawBytes: 20 });
    expect(parseDeviceDiagnosticV1({ v: 1, kind: 'crash', createdAt: 5 })).toBeNull();
    expect(parseDeviceDiagnosticV1({ v: 2 })).toBeNull();
  });
});

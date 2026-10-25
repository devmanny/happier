import { afterEach, describe, expect, it, vi } from 'vitest';

import { createEnvKeyScope } from '@/testkit/env/envScope';
import { createTempDirSync, removeTempDirSync } from '@/testkit/fs/tempDir';
import {
  createEncryptedTransferChunkEnvelope,
  createTransferRecipientKeyPair,
  decryptEncryptedTransferChunkEnvelope,
} from '@/machines/transfer/transferChunkEncryption';

describe('configuration files transfer chunk bytes', () => {
  const envKeys = ['HAPPIER_HOME_DIR', 'HAPPIER_FILES_TRANSFER_CHUNK_BYTES'] as const;
  let envScope = createEnvKeyScope(envKeys);
  const tempDirs: string[] = [];

  afterEach(() => {
    envScope.restore();
    envScope = createEnvKeyScope(envKeys);
    vi.resetModules();
    for (const tempDir of tempDirs) removeTempDirSync(tempDir);
    tempDirs.length = 0;
  });

  it('never advertises a chunk size the transfer receiver rejects', async () => {
    // Upload/download init advertise this size; each chunk is then decrypted against the
    // receiver's hard chunk ceiling. A 4 MB setting used to pass config and fail every chunk.
    const homeDir = createTempDirSync('happier-cli-config-');
    tempDirs.push(homeDir);
    process.env.HAPPIER_HOME_DIR = homeDir;
    process.env.HAPPIER_FILES_TRANSFER_CHUNK_BYTES = String(4_000_000);

    const configMod = await import('./configuration');
    configMod.reloadConfiguration();
    const chunkBytes = configMod.configuration.filesTransferChunkBytes;

    const recipient = createTransferRecipientKeyPair();
    const envelope = createEncryptedTransferChunkEnvelope({
      transferId: 'upload-1',
      sequence: 0,
      payload: Buffer.alloc(chunkBytes, 7),
      recipientPublicKeyBase64: recipient.recipientPublicKeyBase64,
    });
    const decrypted = decryptEncryptedTransferChunkEnvelope({
      transferId: 'upload-1',
      sequence: 0,
      ...envelope,
      recipientSecretKeySeed: recipient.recipientSecretKeySeed,
    });
    expect(decrypted.length).toBe(chunkBytes);
  });
});

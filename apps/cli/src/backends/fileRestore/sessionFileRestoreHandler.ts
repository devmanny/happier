import type { SessionRestoreFilesRpcResult } from '@happier-dev/protocol';

import type { Credentials } from '@/persistence';

/**
 * Agent-owned `session.restoreFiles`: restore the session's working-directory files to just
 * before one committed user message, using the Agent's own file checkpoints. The daemon handler
 * has already loaded and decrypted the session and resolved its Agent; the hook owns everything
 * Agent-specific (finding the checkpoint, the dry run, the real restore). An Agent without this
 * hook is `unsupported`. Errors the hook throws reach the caller as an `UNEXPECTED` failure.
 */
export type SessionFileRestoreHandler = (params: Readonly<{
  credentials: Credentials;
  sessionId: string;
  rawSession: Readonly<{ encryptionMode?: unknown; dataEncryptionKey?: unknown }>;
  metadata: Readonly<Record<string, unknown>>;
  /** The session's normalized working directory. */
  directory: string;
  userMessageSeq: number;
  dryRun: boolean;
  /** The caller's cancellation: once aborted the hook rejects and must not start a real restore. */
  signal?: AbortSignal;
}>) => Promise<SessionRestoreFilesRpcResult>;

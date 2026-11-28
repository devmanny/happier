import type { Credentials } from '@/persistence';
import type { SpawnSessionOptions } from '@/rpc/handlers/registerSessionHandlers';

export class ProviderNativeForkIndeterminateError extends Error {
  constructor() {
    super('The native fork may have completed. Check for a new session before retrying.');
    this.name = 'ProviderNativeForkIndeterminateError';
  }
}

export function isProviderNativeForkIndeterminateError(error: unknown): error is ProviderNativeForkIndeterminateError {
  return error instanceof ProviderNativeForkIndeterminateError;
}

export class ProviderNativeForkFailedBeforeDispatchError extends Error {
  constructor(cause: Error) {
    super(cause.message, { cause });
    this.name = 'ProviderNativeForkFailedBeforeDispatchError';
  }
}

export function isProviderNativeForkFailedBeforeDispatchError(
  error: unknown,
): error is ProviderNativeForkFailedBeforeDispatchError {
  return error instanceof ProviderNativeForkFailedBeforeDispatchError;
}

export type ProviderNativeForkPoint = { type: 'latest' } | { type: 'seq'; upToSeqInclusive: number };

export type ProviderNativeForkDispatchResult = Readonly<{
  vendorSessionId: string;
  spawn: Partial<SpawnSessionOptions>;
  metadata: Record<string, unknown>;
  providerHint: {
    providerId: string;
    backendMode?: string;
    vendorSessionId: string;
  };
}>;

export type ProviderNativeForkHandler = (params: Readonly<{
  credentials: Credentials;
  agentId: string;
  parentSessionId: string;
  parentRawSession: Readonly<{ encryptionMode?: unknown; dataEncryptionKey?: unknown; metadata?: unknown }>;
  parentMetadata: Record<string, unknown>;
  directory: string;
  forkPoint: ProviderNativeForkPoint;
  targetSeqInclusive: number;
  /** Last parent seq the child's lineage shows (before a user-message target, for branch-and-edit). */
  cutoffSeqInclusive: number;
  signal?: AbortSignal;
}>) => Promise<ProviderNativeForkDispatchResult | null>;

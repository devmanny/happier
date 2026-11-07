import axios from 'axios';

import { resolveServerHttpBaseUrl } from '@/api/client/serverHttpBaseUrl';


/** Same budget as the other account-scoped document calls (`/v2/account/settings`). */
const KV_REQUEST_TIMEOUT_MS = 15_000;

type KvRow = Readonly<{ key: string; value: string | null; version: number }>;

/** The relay's UserKVStore (`/v1/kv`), reduced to what account-scoped records need. */
export type AccountKvTransport = Readonly<{
  /** Live rows under `prefix` (deleted rows, whose value is null, are left out). */
  list: (prefix: string) => Promise<ReadonlyArray<Readonly<{ key: string; value: string; version: number }>>>;
  mutate: (mutations: ReadonlyArray<Readonly<{ key: string; value: string | null; version: number }>>) => Promise<
    | Readonly<{ ok: true; results: ReadonlyArray<Readonly<{ key: string; version: number }>> }>
    | Readonly<{ ok: false; current: ReadonlyArray<Readonly<{ key: string; version: number }>> }>
  >;
}>;

/** The relay's UserKVStore routes (`apps/server/sources/app/api/routes/kv/kvRoutes.ts`). */
export function createAccountKvHttpTransport(params: Readonly<{ token: string; baseUrl?: string }>): AccountKvTransport {
  const baseUrl = params.baseUrl ?? resolveServerHttpBaseUrl();
  const headers = { Authorization: `Bearer ${params.token}`, 'Content-Type': 'application/json' };
  return {
    async list(prefix) {
      const response = await axios.get(`${baseUrl}/v1/kv`, {
        headers,
        params: { prefix, limit: 1000 },
        timeout: KV_REQUEST_TIMEOUT_MS,
        validateStatus: () => true,
      });
      if (response.status !== 200 || !Array.isArray(response.data?.items)) {
        throw new Error(`Failed to list /v1/kv (${response.status})`);
      }
      return (response.data.items as KvRow[])
        .filter((item): item is Readonly<{ key: string; value: string; version: number }> => typeof item.value === 'string' && item.value.length > 0);
    },
    async mutate(mutations) {
      const response = await axios.post(`${baseUrl}/v1/kv`, { mutations }, {
        headers,
        timeout: KV_REQUEST_TIMEOUT_MS,
        validateStatus: () => true,
      });
      if (response.status === 200 && Array.isArray(response.data?.results)) {
        return { ok: true, results: response.data.results as Array<{ key: string; version: number }> };
      }
      if (response.status === 409 && Array.isArray(response.data?.errors)
        && (response.data.errors as Array<{ error?: string }>).every((error) => error.error === 'version-mismatch')) {
        return { ok: false, current: response.data.errors as Array<{ key: string; version: number }> };
      }
      throw new Error(`Failed to write /v1/kv (${response.status})`);
    },
  };
}

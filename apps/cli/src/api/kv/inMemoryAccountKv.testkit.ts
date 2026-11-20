import { ACCOUNT_KV_BULK_GET_MAX_KEYS, ACCOUNT_KV_LIST_MAX_ROWS, type AccountKvTransport } from './accountKvHttpTransport';

/** The relay's UserKVStore version rules, in memory: the boundary fake for account-scoped records. */
export function createInMemoryAccountKv() {
  const rows = new Map<string, { value: string | null; version: number }>();
  const transport: AccountKvTransport = {
    async list(prefix) {
      return [...rows.entries()]
        .filter(([key, row]) => key.startsWith(prefix) && row.value !== null)
        .sort(([a], [b]) => (a < b ? -1 : 1))
        .slice(0, ACCOUNT_KV_LIST_MAX_ROWS)
        .map(([key, row]) => ({ key, value: row.value!, version: row.version }));
    },
    async bulkGet(keys) {
      if (keys.length < 1 || keys.length > ACCOUNT_KV_BULK_GET_MAX_KEYS) {
        throw new RangeError(`the relay reads 1 to ${ACCOUNT_KV_BULK_GET_MAX_KEYS} keys at once, not ${keys.length}`);
      }
      return [...new Set(keys)].flatMap((key) => {
        const row = rows.get(key);
        return row && row.value !== null ? [{ key, value: row.value, version: row.version }] : [];
      });
    },
    async mutate(mutations) {
      const conflicts = mutations.filter((m) => (rows.get(m.key)?.version ?? -1) !== m.version);
      if (conflicts.length > 0) {
        return { ok: false, current: conflicts.map((m) => ({ key: m.key, version: rows.get(m.key)?.version ?? -1 })) };
      }
      const results = mutations.map((m) => {
        const version = m.version + 1;
        rows.set(m.key, { value: m.value, version });
        return { key: m.key, version };
      });
      return { ok: true, results };
    },
  };
  return { rows, transport };
}

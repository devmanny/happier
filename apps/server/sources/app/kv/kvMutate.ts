import { inTx, afterTx } from "@/storage/inTx";
import { randomKeyNaked } from "@/utils/keys/randomKeyNaked";
import { eventRouter, buildKVBatchUpdateUpdate } from "@/app/events/eventRouter";
import * as privacyKit from "privacy-kit";
import { markAccountChanged } from "@/app/changes/markAccountChanged";
import { accountKvChangeFamily } from "@happier-dev/protocol/changes";
import { isPublicAccountScopedKvKey } from "./reservedAccountScopedKvRow";
import { mutateAccountScopedKvRowsInTx } from "./accountScopedKv";

export interface KVMutation {
    key: string;
    value: string | null; // null = delete (sets value to null but keeps record)
    version: number; // Always required, use -1 for new keys
}

export interface KVMutateResult {
    success: boolean;
    results?: Array<{
        key: string;
        version: number;
    }>;
    errors?: Array<{
        key: string;
        error: 'version-mismatch' | 'reserved-key';
        version: number;
        value: string | null;  // Current value (null if deleted)
    }>;
}

/**
 * Atomically mutate multiple key-value pairs.
 * All mutations succeed or all fail.
 * Version is always required for all operations (use -1 for new keys).
 * Delete operations set value to null but keep the record with incremented version.
 * Sends a single bundled update notification for all changes.
 */
export async function kvMutate(
    ctx: { uid: string },
    mutations: KVMutation[]
): Promise<KVMutateResult> {
    const reservedErrors = mutations
        .filter((mutation) => !isPublicAccountScopedKvKey(mutation.key))
        .map((mutation) => ({
            key: mutation.key,
            error: 'reserved-key' as const,
            version: -1,
            value: null,
        }));
    if (reservedErrors.length > 0) {
        return { success: false, errors: reservedErrors };
    }

    return await inTx(async (tx) => {
        const mutationResult = await mutateAccountScopedKvRowsInTx(tx, {
            accountId: ctx.uid,
            mutations: mutations.map((mutation) => ({
                key: mutation.key,
                value: mutation.value ? privacyKit.decodeBase64(mutation.value) : null,
                expectedVersion: mutation.version,
            })),
        });
        if (mutationResult.status === 'conflict') {
            const currentByKey = new Map(mutationResult.rows.map((row) => [row.key, row]));
            return {
                success: false,
                errors: mutations
                    .filter((mutation) => (currentByKey.get(mutation.key)?.version ?? -1) !== mutation.version)
                    .map((mutation) => {
                        const current = currentByKey.get(mutation.key);
                        return {
                            key: mutation.key,
                            error: 'version-mismatch' as const,
                            version: current?.version ?? -1,
                            value: current?.value ? privacyKit.encodeBase64(current.value) : null,
                        };
                    }),
            };
        }

        const results = mutationResult.rows.map((row) => ({ key: row.key, version: row.version }));
        const changes = mutationResult.rows.map((row) => ({
            key: row.key,
            value: mutations.find((mutation) => mutation.key === row.key)?.value ?? null,
            version: row.version,
        }));

        const uniqueKeys = Array.from(new Set(mutations.map((m) => m.key)));
        // One change row per key family (see `accountKvChangeFamily`).
        const byFamily = new Map<string, string[]>();
        for (const key of uniqueKeys) {
            const family = accountKvChangeFamily(key);
            byFamily.set(family, [...(byFamily.get(family) ?? []), key]);
        }
        let cursor = 0;
        for (const [family, keys] of byFamily) {
            const hint = keys.length <= 50 ? { keys } : { full: true };
            cursor = await markAccountChanged(tx, { accountId: ctx.uid, kind: 'kv', entityId: family, hint });
        }

        // Send single bundled notification for all changes
        afterTx(tx, async () => {
            eventRouter.emitUpdate({
                userId: ctx.uid,
                payload: buildKVBatchUpdateUpdate(changes, cursor, randomKeyNaked(12)),
                recipientFilter: { type: 'user-scoped-only' }
            });
        });

        return { success: true, results };
    });
}

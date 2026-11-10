import { randomUUID } from "node:crypto";

import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

import { createSessionPublisherPresence } from "@/app/presence/sessionPublisherPresence";
import { enqueuePendingMessage } from "@/app/session/pending/pendingMessageService";
import { db } from "@/storage/db";
import { createLightSqliteHarness, type LightSqliteHarness } from "@/testkit/lightSqliteHarness";
import { createFakeSocket, getSocketHandler } from "../testkit/socketHarness";

import { sessionUpdateHandler } from "./sessionUpdateHandler";

describe("not-received Pending delivery from the current runner on SQLite", () => {
    let harness: LightSqliteHarness;

    beforeAll(async () => {
        harness = await createLightSqliteHarness({
            tempDirPrefix: "happier-not-received-pending-",
            initAuth: false,
            initEncrypt: false,
            initFiles: false,
        });
    });
    beforeEach(() => harness.resetEnv());
    afterAll(async () => await harness.close());

    it("returns a replaced runner's uncertain claim to its place in line only for the current runner", async () => {
        const owner = await db.account.create({ data: { publicKey: `pk-${randomUUID()}` }, select: { id: true } });
        const session = await db.session.create({
            data: { tag: `session-${randomUUID()}`, accountId: owner.id, metadata: "{}", metadataVersion: 0, agentState: null, agentStateVersion: 0 },
            select: { id: true },
        });
        const machineId = `machine-${randomUUID()}`;
        await db.machine.create({ data: { id: machineId, accountId: owner.id, metadata: "{}" } });
        await db.accessKey.create({ data: { accountId: owner.id, machineId, sessionId: session.id, data: "encrypted" } });
        const localId = `pending-${randomUUID()}`;
        await enqueuePendingMessage({
            actorUserId: owner.id, sessionId: session.id, localId, ciphertext: "ciphertext", requestedAction: { v: 1, kind: "enqueue" },
        });

        let nowMs = new Date("2026-11-10T16:39:28.000Z").getTime();
        const presence = createSessionPublisherPresence({ now: () => new Date(nowMs++) });
        const binding = { accountId: owner.id, machineId, sessionId: session.id };
        const sessionScopedSocket = (id: string) => createFakeSocket({
            id,
            data: { clientType: "session-scoped", sessionScopedBinding: { sessionId: session.id, machineId, proof: "machine-access-key" } },
        });
        const predecessorSocket = sessionScopedSocket("predecessor-socket");
        const successorSocket = sessionScopedSocket("successor-socket");
        expect((await presence.registerPublisher({ socket: predecessorSocket, binding, completeActivitySnapshot: { state: "idle", activeCount: 0 } })).status).toBe("registered");
        await db.sessionPendingMessage.update({
            where: { sessionId_localId: { sessionId: session.id, localId } },
            data: { deliveryState: "delivering", providerAction: "send" },
        });
        // The replacement runner registers: the in-flight claim becomes durable uncertainty.
        expect((await presence.registerPublisher({ socket: successorSocket, binding, completeActivitySnapshot: { state: "idle", activeCount: 0 } })).status).toBe("registered");
        const readRow = () => db.sessionPendingMessage.findUniqueOrThrow({
            where: { sessionId_localId: { sessionId: session.id, localId } },
            select: { status: true, deliveryState: true, deliveryBlockedReason: true, providerAction: true },
        });
        await expect(readRow()).resolves.toEqual({
            status: "queued", deliveryState: "blocked", deliveryBlockedReason: "delivery_outcome_uncertain", providerAction: "send",
        });

        const emitFrom = async (socket: ReturnType<typeof createFakeSocket>, connectionType: "session-scoped" | "user-scoped") => {
            sessionUpdateHandler(owner.id, socket as any, { connectionType, socket, userId: owner.id, sessionId: session.id } as any, {
                presence,
                binding,
            });
            const callback = vi.fn();
            await getSocketHandler(socket, "pending-delivery-not-received-v1")({ v: 1, sessionId: session.id, localId }, callback);
            return callback.mock.calls[0]?.[0];
        };

        // The replaced runner, or a connection that is not the session's runner, has no authority.
        await expect(emitFrom(predecessorSocket, "session-scoped")).resolves.toEqual({ ok: false, error: "forbidden" });
        await expect(emitFrom(createFakeSocket({ id: "user-socket" }), "user-scoped")).resolves.toEqual({ ok: false, error: "forbidden" });
        await expect(readRow()).resolves.toMatchObject({ deliveryState: "blocked" });

        await expect(emitFrom(successorSocket, "session-scoped")).resolves.toMatchObject({
            ok: true, didRequeue: true, pendingCount: 1, pendingBlockedCount: 0,
        });
        await expect(readRow()).resolves.toEqual({ status: "queued", deliveryState: null, deliveryBlockedReason: null, providerAction: null });
    });
});

import { afterEach, describe, expect, it, vi } from "vitest";

import { createServer } from "node:http";
import { createRequire } from "node:module";
import { connect as netConnect } from "node:net";
import { Server } from "socket.io";

import { eventRouter } from "./eventRouter";
import { getSocketRooms, readsLeanUpdates, registerOpenSessionsEvent, UPDATES_LEAN_V1_CAPABILITY } from "@/app/api/socketRooms";
import { ConnectedServiceIdSchema } from "@happier-dev/protocol";

const require = createRequire(import.meta.url);
const { io: ioClient } = require("socket.io-client") as typeof import("socket.io-client");

async function startTestIoServer() {
    const httpServer = createServer();
    const seenRequests: string[] = [];
    const seenUpgrades: string[] = [];
    httpServer.on("request", (req) => {
        if (req.url) seenRequests.push(req.url);
    });
    httpServer.on("upgrade", (req) => {
        if (req.url) seenUpgrades.push(req.url);
    });
    const io = new Server(httpServer, {
        path: "/v1/updates",
        serveClient: false,
    });

    io.on("connection", (socket) => {
        const userId = socket.handshake.auth.userId as string | undefined;
        if (!userId) {
            socket.disconnect();
            return;
        }

        const clientType = socket.handshake.auth.clientType as any;
        const sessionId = socket.handshake.auth.sessionId as string | undefined;
        const machineId = socket.handshake.auth.machineId as string | undefined;

        socket.join(getSocketRooms({ userId, clientType, sessionId, machineId, connectedServiceIds: socket.handshake.auth.connectedServiceIds, capabilities: socket.handshake.auth.capabilities }));
        registerOpenSessionsEvent(socket, userId, clientType === "user-scoped" && readsLeanUpdates(socket.handshake.auth.capabilities));
    });

    await new Promise<void>((resolve) => {
        httpServer.listen(0, () => resolve());
    });

    const address = httpServer.address();
    if (!address || typeof address === "string") {
        throw new Error("Failed to bind test server");
    }

    const url = `http://localhost:${address.port}`;

    // Sanity-check that the server port is reachable before Socket.IO attempts to connect.
    await new Promise<void>((resolve, reject) => {
        const s = netConnect(address.port, "127.0.0.1");
        s.once("connect", () => {
            s.end();
            resolve();
        });
        s.once("error", reject);
    });

    return {
        url,
        io,
        seenRequests,
        seenUpgrades,
        close: async () => {
            // Socket.IO closes the underlying HTTP server when constructed with an httpServer instance.
            await io.close();
        },
    };
}

function connectClient(params: {
    url: string;
    userId: string;
    clientType: "session-scoped" | "user-scoped" | "machine-scoped";
    sessionId?: string;
    machineId?: string;
    connectedServiceIds?: readonly string[];
    capabilities?: readonly string[];
}) {
    const socket = ioClient(params.url, {
        path: "/v1/updates",
        auth: {
            userId: params.userId,
            clientType: params.clientType,
            ...(params.sessionId ? { sessionId: params.sessionId } : {}),
            ...(params.machineId ? { machineId: params.machineId } : {}),
            ...(params.connectedServiceIds ? { connectedServiceIds: params.connectedServiceIds } : {}),
            ...(params.capabilities ? { capabilities: params.capabilities } : {}),
        },
        reconnection: false,
        autoConnect: true,
    });

    return socket;
}

async function waitForConnect(socket: any) {
    if (socket.connected) return;
    await new Promise<void>((resolve, reject) => {
        const onConnect = () => {
            cleanup();
            resolve();
        };
        const onError = (err: any) => {
            cleanup();
            reject(new Error(err?.message || String(err)));
        };
        const cleanup = () => {
            socket.off("connect", onConnect);
            socket.off("connect_error", onError);
        };
        socket.on("connect", onConnect);
        socket.on("connect_error", onError);
    });
}

describe("eventRouter session room isolation (integration)", () => {
    afterEach(() => {
        eventRouter.clearIo();
    });

    it("projects account and runtime issue updates for released readers without losing failure facts or account isolation", async () => {
        const server = await startTestIoServer();
        eventRouter.setIo(server.io);
        const released = connectClient({ url: server.url, userId: "u1", clientType: "user-scoped" });
        const current = connectClient({ url: server.url, userId: "u1", clientType: "session-scoped", sessionId: "s1", connectedServiceIds: ConnectedServiceIdSchema.options });
        const other = connectClient({ url: server.url, userId: "u2", clientType: "session-scoped", sessionId: "s1" });
        try {
            await Promise.all([waitForConnect(released), waitForConnect(current), waitForConnect(other)]);
            const releasedUpdates: unknown[] = [];
            const currentUpdates: unknown[] = [];
            const otherUpdates: unknown[] = [];
            released.on("update", (payload) => releasedUpdates.push(payload));
            current.on("update", (payload) => currentUpdates.push(payload));
            other.on("update", (payload) => otherUpdates.push(payload));
            const issue = {
                v: 1, scope: "primary_session", status: "failed", source: "usage_limit", code: "usage_limit", occurredAt: 12, provider: "agy",
                usageLimit: { v: 1, resetAtMs: 500, retryAfterMs: 200, quotaScope: "account", recoverability: "switch_account",
                    connectedService: { serviceId: "antigravity", profileId: "work", groupId: null },
                    quotaSnapshotRef: { serviceId: "antigravity", profileId: "work" },
                },
            };
            eventRouter.emitUpdate({ userId: "u1", payload: { id: "issue", seq: 1, createdAt: 12, body: { t: "update-session", id: "s1", latestTurnStatus: "failed", lastRuntimeIssue: issue } }, recipientFilter: { type: "all-interested-in-session", sessionId: "s1" } });
            const account = { connectedServicesV2: [{ serviceId: "antigravity", profiles: [], groups: [] }], connectedServiceCredentialRevisionsV1: [{ serviceId: "antigravity", profileId: "work", credentialRevision: "csr_abcdefghijklmnopqrstuv" }] };
            eventRouter.emitUpdate({ userId: "u1", payload: { id: "account", seq: 2, createdAt: 12, body: { t: "update-account", ...account } }, recipientFilter: { type: "all-user-authenticated-connections" } });
            await vi.waitFor(() => {
                expect(releasedUpdates).toHaveLength(2);
                expect(currentUpdates).toHaveLength(2);
            });
            expect(releasedUpdates[0]).toMatchObject({ body: { latestTurnStatus: "failed", lastRuntimeIssue: { provider: "agy", usageLimit: { resetAtMs: 500, retryAfterMs: 200 } } } });
            expect(releasedUpdates[0]).not.toHaveProperty("body.lastRuntimeIssue.usageLimit.connectedService");
            expect(releasedUpdates[0]).not.toHaveProperty("body.lastRuntimeIssue.usageLimit.quotaSnapshotRef");
            expect(releasedUpdates[1]).toMatchObject({ body: { connectedServicesV2: [], connectedServiceCredentialRevisionsV1: [] } });
            expect(currentUpdates[0]).toHaveProperty("body.lastRuntimeIssue.usageLimit.connectedService.serviceId", "antigravity");
            expect(currentUpdates[1]).toMatchObject({ body: account });
            expect(otherUpdates).toHaveLength(0);
            expect(issue.usageLimit.connectedService.serviceId).toBe("antigravity");
        } finally {
            released.disconnect(); current.disconnect(); other.disconnect();
            await server.close();
        }
    });

    it("does not leak recipient-specific updates across users who share a sessionId", async () => {
        const server = await startTestIoServer();
        eventRouter.setIo(server.io as any);

        const u1 = connectClient({ url: server.url, userId: "u1", clientType: "session-scoped", sessionId: "s1" });
        const u2 = connectClient({ url: server.url, userId: "u2", clientType: "session-scoped", sessionId: "s1" });

        try {
            try {
                await Promise.all([waitForConnect(u1), waitForConnect(u2)]);
            } catch (err) {
                throw new Error(
                    `Socket connect failed: ${(err as any)?.message || String(err)} (requests=${server.seenRequests.length}, upgrades=${server.seenUpgrades.length})`
                );
            }

            const receivedByU1: any[] = [];
            const receivedByU2: any[] = [];

            u1.on("update", (data) => receivedByU1.push(data));
            u2.on("update", (data) => receivedByU2.push(data));

            eventRouter.emitUpdate({
                userId: "u1",
                payload: {
                    id: "upd-1",
                    seq: 10,
                    createdAt: Date.now(),
                    body: {
                        // This update type can include secrets (token), so it must never fan out to other users.
                        t: "public-share-created",
                        sessionId: "s1",
                        publicShareId: "ps1",
                        token: "tok",
                        expiresAt: null,
                        maxUses: null,
                        isConsentRequired: false,
                        updatedAt: Date.now(),
                    },
                } as any,
                recipientFilter: { type: "all-interested-in-session", sessionId: "s1" },
            });

            await vi.waitFor(() => {
                expect(receivedByU1.some((payload) => payload?.id === "upd-1")).toBe(true);
            });
            expect(receivedByU2.some((payload) => payload?.id === "upd-1")).toBe(false);

            // Prove that two recipients can legitimately have different cursors, and they must not receive each other's containers.
            eventRouter.emitUpdate({
                userId: "u2",
                payload: { id: "upd-2", seq: 20, createdAt: Date.now(), body: { t: "new-message", sid: "s1", msg: {} } } as any,
                recipientFilter: { type: "all-interested-in-session", sessionId: "s1" },
            });

            await vi.waitFor(() => {
                expect(receivedByU2.some((payload) => payload?.id === "upd-2")).toBe(true);
            });
            expect(receivedByU1.some((payload) => payload?.id === "upd-2")).toBe(false);
        } finally {
            u1.disconnect();
            u2.disconnect();
            await server.close();
        }
    });

    it("does not deliver catch-all authenticated-user broadcasts to machine-scoped sockets", async () => {
        const server = await startTestIoServer();
        eventRouter.setIo(server.io as any);

        const userScoped = connectClient({ url: server.url, userId: "u1", clientType: "user-scoped" });
        const machineScoped = connectClient({
            url: server.url,
            userId: "u1",
            clientType: "machine-scoped",
            machineId: "m1",
        });

        try {
            await Promise.all([waitForConnect(userScoped), waitForConnect(machineScoped)]);

            const receivedByUserScoped: any[] = [];
            const receivedByMachineScoped: any[] = [];

            userScoped.on("update", (data) => receivedByUserScoped.push(data));
            machineScoped.on("update", (data) => receivedByMachineScoped.push(data));

            eventRouter.emitUpdate({
                userId: "u1",
                payload: { id: "upd-all", seq: 1, createdAt: Date.now(), body: { t: "public-share-created" } } as any,
                recipientFilter: { type: "all-user-authenticated-connections" },
            });

            await vi.waitFor(() => {
                expect(receivedByUserScoped.some((payload) => payload?.id === "upd-all")).toBe(true);
            });
            expect(receivedByMachineScoped.some((payload) => payload?.id === "upd-all")).toBe(false);
        } finally {
            userScoped.disconnect();
            machineScoped.disconnect();
            await server.close();
        }
    });

    it("delivers user-machine-scoped broadcasts to machine-scoped sockets only", async () => {
        const server = await startTestIoServer();
        eventRouter.setIo(server.io as any);

        const userScoped = connectClient({ url: server.url, userId: "u1", clientType: "user-scoped" });
        const machineScoped = connectClient({
            url: server.url,
            userId: "u1",
            clientType: "machine-scoped",
            machineId: "m1",
        });

        try {
            await Promise.all([waitForConnect(userScoped), waitForConnect(machineScoped)]);

            const receivedByUserScoped: any[] = [];
            const receivedByMachineScoped: any[] = [];

            userScoped.on("update", (data) => receivedByUserScoped.push(data));
            machineScoped.on("update", (data) => receivedByMachineScoped.push(data));

            eventRouter.emitUpdate({
                userId: "u1",
                payload: { id: "upd-settings", seq: 1, createdAt: Date.now(), body: { t: "account-settings-changed", settingsVersion: 2 } } as any,
                recipientFilter: { type: "user-machine-scoped-only" },
            });

            await vi.waitFor(() => {
                expect(receivedByMachineScoped.some((payload) => payload?.id === "upd-settings")).toBe(true);
            });
            expect(receivedByUserScoped.some((payload) => payload?.id === "upd-settings")).toBe(false);
        } finally {
            userScoped.disconnect();
            machineScoped.disconnect();
            await server.close();
        }
    });
    it("sends lean readers state changes and full messages only for the sessions they have open; released readers get everything", async () => {
        const server = await startTestIoServer();
        eventRouter.setIo(server.io as any);
        const released = connectClient({ url: server.url, userId: "u1", clientType: "user-scoped" });
        const lean = connectClient({ url: server.url, userId: "u1", clientType: "user-scoped", capabilities: [UPDATES_LEAN_V1_CAPABILITY] });
        try {
            await Promise.all([waitForConnect(released), waitForConnect(lean)]);
            const got = { released: [] as any[], lean: [] as any[] };
            released.onAny((event: string, payload: any) => got.released.push({ event, payload }));
            lean.onAny((event: string, payload: any) => got.lean.push({ event, payload }));
            await lean.emitWithAck("client-open-sessions", { sessionIds: ["s-open"] });

            const message = (sid: string, seq: number) => ({ id: `m${seq}`, seq: 100 + seq, createdAt: 1,
                body: { t: "new-message", sid, id: sid, message: { id: `msg${seq}`, seq, localId: null, content: { t: "encrypted", c: "SECRET" }, createdAt: 1, updatedAt: 1 } } });
            const interested = (sessionId: string) => ({ type: "all-interested-in-session" as const, sessionId });
            // A heartbeat (only active/activeAt) and a real state change.
            eventRouter.emitUpdate({ userId: "u1", leanReaders: "skip", payload: { id: "h", seq: 1, createdAt: 1, body: { t: "update-session", id: "s-closed", sid: "s-closed", active: true, activeAt: 5 } } as any, recipientFilter: interested("s-closed") });
            eventRouter.emitUpdate({ userId: "u1", payload: { id: "st", seq: 2, createdAt: 1, body: { t: "update-session", id: "s-closed", sid: "s-closed", latestTurnStatus: "running" } } as any, recipientFilter: interested("s-closed") });
            eventRouter.emitUpdate({ userId: "u1", payload: message("s-closed", 1) as any, recipientFilter: interested("s-closed") });
            eventRouter.emitUpdate({ userId: "u1", payload: message("s-open", 2) as any, recipientFilter: interested("s-open") });
            eventRouter.emitEphemeral({ userId: "u1", payload: { type: "transcript-stream-segment-delta", sessionId: "s-closed", delta: "x" } as any, recipientFilter: interested("s-closed") });
            eventRouter.emitEphemeral({ userId: "u1", payload: { type: "transcript-stream-segment-delta", sessionId: "s-open", delta: "y" } as any, recipientFilter: interested("s-open") });

            await vi.waitFor(() => {
                expect(got.released).toHaveLength(6);
                expect(got.lean).toHaveLength(4);
            });
            // Released readers: exactly as before.
            expect(got.released.map((e) => e.payload.body?.t ?? e.payload.type)).toEqual([
                "update-session", "update-session", "new-message", "new-message", "transcript-stream-segment-delta", "transcript-stream-segment-delta"]);
            expect(got.released[2].payload.body.message.content).toEqual({ t: "encrypted", c: "SECRET" });
            // Lean: no heartbeat; the state change; a light notice for the closed session; the open one in full, with its stream.
            expect(got.lean[0].payload.body).toMatchObject({ t: "update-session", latestTurnStatus: "running" });
            expect(got.lean[1].payload.body).toMatchObject({ t: "new-message", sid: "s-closed", message: { id: "msg1", seq: 1, contentOmitted: true } });
            expect(got.lean[1].payload.body.message).not.toHaveProperty("content");
            expect(got.lean[1].payload.seq).toBe(101);
            expect(got.lean[2].payload.body.message.content).toEqual({ t: "encrypted", c: "SECRET" });
            expect(got.lean[3].payload).toMatchObject({ type: "transcript-stream-segment-delta", sessionId: "s-open" });

            // Closing it (an empty list) turns that session back to light notices.
            await lean.emitWithAck("client-open-sessions", { sessionIds: [] });
            eventRouter.emitEphemeral({ userId: "u1", payload: { type: "transcript-stream-segment-delta", sessionId: "s-open", delta: "z" } as any, recipientFilter: interested("s-open") });
            eventRouter.emitUpdate({ userId: "u1", payload: message("s-open", 3) as any, recipientFilter: interested("s-open") });
            await vi.waitFor(() => expect(got.lean).toHaveLength(5));
            expect(got.lean[4].payload.body.message).toMatchObject({ seq: 3, contentOmitted: true });
        } finally {
            released.disconnect(); lean.disconnect();
            await server.close();
        }
    });
});

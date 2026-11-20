import { ConnectedServiceIdSchema, readConnectedServiceReaderSupport } from "@happier-dev/protocol";

export type SocketClientType = "session-scoped" | "user-scoped" | "machine-scoped";

export const RELEASED_CONNECTED_SERVICE_READER_ROOM = "connected-services-reader:released";
export const CURRENT_CONNECTED_SERVICE_READER_ROOM = "connected-services-reader:current";

export function getConnectedServiceReaderRoom(raw: unknown): string {
    const supportedIds = readConnectedServiceReaderSupport(raw);
    return ConnectedServiceIdSchema.options.every(serviceId => supportedIds.includes(serviceId))
        ? CURRENT_CONNECTED_SERVICE_READER_ROOM
        : RELEASED_CONNECTED_SERVICE_READER_ROOM;
}

/**
 * A user-scoped client that declares this capability when it connects (`auth.capabilities`) is a
 * lean reader: it isn't sent publisher heartbeats that only refresh `active`/`activeAt`, and gets
 * full messages and transcript streams only for the sessions it declared open
 * (`client-open-sessions`); for the others a light `new-message`/`message-updated` notice without
 * the content. Clients that don't declare it receive everything as before.
 */
export const UPDATES_LEAN_V1_CAPABILITY = "updates-lean-v1";

/**
 * Sessions one socket may declare open at once: each is a Socket.IO room membership the server
 * holds for the connection. The apps open a handful (split view, a few Mac windows); a list beyond
 * this keeps its first entries and the ack says it was cut.
 */
export const MAX_DECLARED_OPEN_SESSIONS = 64;

export function leanReaderRoom(userId: string): string {
    return `updates-lean:${userId}`;
}

export function openSessionRoom(userId: string, sessionId: string): string {
    return `session-open:${userId}:${sessionId}`;
}

export function readsLeanUpdates(capabilities: unknown): boolean {
    return Array.isArray(capabilities) && capabilities.includes(UPDATES_LEAN_V1_CAPABILITY);
}

type OpenSessionsSocket = Readonly<{
    data: unknown;
    join(room: string | string[]): unknown;
    leave(room: string): unknown;
    on(event: string, listener: (data: unknown, ack?: (response: unknown) => void) => void): unknown;
}>;

/**
 * `client-open-sessions {sessionIds}`: the sessions a lean reader shows right now, replacing its
 * previous list. Only lean readers use it (others already receive everything).
 */
export function registerOpenSessionsEvent(socket: OpenSessionsSocket, userId: string, isLeanReader: boolean): void {
    if (!isLeanReader) return;
    let joined: string[] = [];
    socket.on("client-open-sessions", (data, ack) => {
        const raw = (data as { sessionIds?: unknown } | null)?.sessionIds;
        const ids = Array.from(new Set((Array.isArray(raw) ? raw : [])
            .filter((id): id is string => typeof id === "string" && id.trim().length > 0)));
        const kept = ids.slice(0, MAX_DECLARED_OPEN_SESSIONS);
        const next = kept.map((id) => openSessionRoom(userId, id));
        for (const room of joined) if (!next.includes(room)) socket.leave(room);
        if (next.length > 0) socket.join(next);
        joined = next;
        (socket.data as { openSessionIds?: ReadonlySet<string> }).openSessionIds = new Set(kept);
        ack?.({ ok: true, count: kept.length, ...(kept.length < ids.length ? { truncated: true } : {}) });
    });
}

export function getSocketRooms(params: {
    userId: string;
    clientType: SocketClientType;
    sessionId?: string | undefined;
    machineId?: string | undefined;
    connectedServiceIds?: unknown;
    capabilities?: unknown;
}): string[] {
    if (!params.userId) {
        throw new Error("getSocketRooms: userId is required");
    }

    const rooms: string[] = [];

    if (params.clientType === "user-scoped") {
        rooms.push(`user:${params.userId}`);
        rooms.push(`user-scoped:${params.userId}`);
        if (readsLeanUpdates(params.capabilities)) rooms.push(leanReaderRoom(params.userId));
    }

    if (params.clientType === "session-scoped") {
        if (!params.sessionId) {
            throw new Error("getSocketRooms: sessionId is required for session-scoped clients");
        }
        rooms.push(`user:${params.userId}`);
        // Important: `session:${sessionId}` is a shared room across participants and must never receive per-account `update`
        // containers (they contain per-account cursors and may contain recipient-specific data). We still join it for future
        // broadcast-safe session events.
        rooms.push(`session:${params.sessionId}`);

        // Per-account session room (safe for recipient-specific updates).
        rooms.push(`session:${params.sessionId}:${params.userId}`);
    }

    if (params.clientType === "machine-scoped") {
        if (!params.machineId) {
            throw new Error("getSocketRooms: machineId is required for machine-scoped clients");
        }
        // Machine daemons should not subscribe to the generic user room. That room is the fanout target
        // for "all authenticated connections" events, and Bun's long-lived socket clients retain native
        // memory aggressively under websocket churn. Keep machine daemons on the dedicated per-machine room.
        rooms.push(`user-machines:${params.userId}`);
        rooms.push(`machine:${params.machineId}:${params.userId}`);
    }

    // Reader rooms are exclusion cohorts only; emission remains scoped to the
    // original account/session/machine rooms, preserving participant isolation.
    rooms.push(getConnectedServiceReaderRoom(params.connectedServiceIds));
    return rooms;
}

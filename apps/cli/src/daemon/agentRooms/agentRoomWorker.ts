import { parseAgentRoomKvKey } from '@happier-dev/protocol';

import { createAccountKvHttpTransport } from '@/api/kv/accountKvHttpTransport';
import { createUserScopedSocket, UPDATES_LEAN_V1_CAPABILITY } from '@/api/session/sockets';
import { agentThreadSpawnOptions, readAgentProfileFromKv, sendToAgentThread } from '@/daemon/agents/agentThreadSpawn';
import { resolveAccountScopedCryptoMaterial, type Credentials } from '@/persistence';
import type { SpawnSessionOptions, SpawnSessionResult } from '@/rpc/handlers/registerSessionHandlers';
import { AgentRoomStore } from '@/session/agentRooms/agentRoomStore';
import type { RoomPushSender } from '@/session/agentRooms/completeRoomTurn';
import { pushEnabledInAccountSettings } from '@/session/agentRooms/startAgentRooms';
import { awaitSpawnedSessionId, type SpawnSessionNonceResolver } from '@/session/services/awaitSpawnedSessionId';
import { readTurnReplyAfterLocalId } from '@/session/services/readTurnReplyAfterLocalId';
import { logger } from '@/ui/logger';

import { reconcileRoomDeliveries, type RoomDeliveryDeps } from './reconcileRoomDeliveries';

/** The relay socket the worker listens on: KV writes arrive as `kv-batch-update` updates. */
export type RoomUpdatesSocket = Readonly<{
  onConnect: (listener: () => void) => void;
  onUpdate: (listener: (update: unknown) => void) => void;
  connect: () => void;
  disconnect: () => void;
}>;

export type AgentRoomWorkerHandle = Readonly<{
  stop: () => void;
  /** Resolves once the room runs started so far have finished. */
  settled: () => Promise<void>;
}>;

function changedRoomIds(update: unknown): string[] {
  const body = (update as { body?: { t?: unknown; changes?: unknown } } | null)?.body;
  if (body?.t !== 'kv-batch-update' || !Array.isArray(body.changes)) return [];
  const ids = new Set<string>();
  for (const change of body.changes as Array<{ key?: unknown }>) {
    const parsed = typeof change?.key === 'string' ? parseAgentRoomKvKey(change.key) : null;
    if (parsed) ids.add(parsed.roomId);
  }
  return [...ids];
}

/**
 * Delivers room messages to this machine's members with the app closed. The machine socket does
 * not carry account KV writes, so the worker listens on a lean user-scoped socket: every write to a
 * room (a message, its seats, the room itself) runs that room's reconciliation, and each (re)connect
 * runs every room this machine has a member in, catching up on what came while it was away. One run
 * per room at a time; a write during a run runs it again after.
 */
export function runAgentRoomWorker(params: Readonly<{
  socket: RoomUpdatesSocket;
  deps: RoomDeliveryDeps;
}>): AgentRoomWorkerHandle {
  const { socket, deps } = params;
  const running = new Map<string, Promise<void>>();
  const again = new Set<string>();
  let stopped = false;

  const schedule = (roomId: string) => {
    if (stopped) return;
    if (running.has(roomId)) {
      again.add(roomId);
      return;
    }
    const run = (async () => {
      do {
        again.delete(roomId);
        await reconcileRoomDeliveries(roomId, deps).catch((error: unknown) => {
          logger.warn('[ROOMS] Room reconciliation failed (retried on the room\'s next change)', {
            roomId, error: error instanceof Error ? error.message : String(error),
          });
        });
      } while (again.has(roomId) && !stopped);
    })().finally(() => running.delete(roomId));
    running.set(roomId, run);
  };

  socket.onConnect(() => {
    void deps.store.listRooms().then(({ rooms, complete }) => {
      if (!complete) logger.warn('[ROOMS] More rooms than one listing holds; some are caught up only on their next change');
      for (const room of rooms) {
        if (room.members.some((member) => member.machineId === deps.machineId)) schedule(room.id);
      }
    }).catch((error: unknown) => {
      logger.warn('[ROOMS] Could not list rooms to catch up', { error: error instanceof Error ? error.message : String(error) });
    });
  });
  socket.onUpdate((update) => {
    for (const roomId of changedRoomIds(update)) schedule(roomId);
  });
  socket.connect();

  return {
    stop: () => {
      stopped = true;
      socket.disconnect();
    },
    settled: async () => {
      while (running.size > 0) await Promise.all([...running.values()]);
    },
  };
}

/** The daemon's room worker for this machine, on the account's relay; null without account encryption. */
export function startAgentRoomWorker(params: Readonly<{
  credentials: Credentials;
  machineId: string;
  spawnSession: (options: SpawnSessionOptions) => Promise<SpawnSessionResult>;
  /** Settles a spawn the daemon accepted before it knew the session id (`daemon.spawnSession.resolve`). */
  resolveSpawnSessionByNonce: SpawnSessionNonceResolver;
  push: RoomPushSender;
}>): AgentRoomWorkerHandle | null {
  const { credentials } = params;
  if (!credentials.encryption) return null;
  const transport = createAccountKvHttpTransport({ token: credentials.token });
  const material = resolveAccountScopedCryptoMaterial(credentials);
  const deps: RoomDeliveryDeps = {
    store: new AgentRoomStore({ transport, material }),
    machineId: params.machineId,
    readAgentProfile: (agentId) => readAgentProfileFromKv(transport, material, agentId),
    startThread: async (spawn, firstInput) => {
      const result = await params.spawnSession({
        ...agentThreadSpawnOptions(spawn, Date.now()),
        approvedNewDirectoryCreation: true,
        spawnNonce: firstInput.localId,
        pendingFirstInput: { text: firstInput.text, localId: firstInput.localId },
      });
      const settled = await awaitSpawnedSessionId({ result, resolveSpawnSessionByNonce: params.resolveSpawnSessionByNonce });
      return settled.type === 'success'
        ? { ok: true, sessionId: settled.sessionId }
        : { ok: false, code: settled.errorCode, message: settled.errorMessage };
    },
    sendToThread: (sessionId, message, localId, permissionMode) =>
      sendToAgentThread({ credentials, sessionId, message, localId, permissionMode }),
    readTurnReply: (sessionId, localId) => readTurnReplyAfterLocalId({ credentials, sessionId, localId }),
    push: params.push,
    pushEnabled: pushEnabledInAccountSettings,
  };
  const io = createUserScopedSocket({ token: credentials.token, capabilities: [UPDATES_LEAN_V1_CAPABILITY], reconnection: true });
  const socket: RoomUpdatesSocket = {
    onConnect: (listener) => { io.on('connect', listener); },
    onUpdate: (listener) => { io.on('update', listener); },
    connect: () => { io.connect(); },
    disconnect: () => { io.disconnect(); },
  };
  return runAgentRoomWorker({ socket, deps });
}

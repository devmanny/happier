import { randomBytes as nodeRandomBytes } from 'node:crypto';

import {
  agentRoomKvKey,
  agentRoomMessageKvKey,
  appendRoomMessage,
  openAccountScopedBlobCiphertext,
  parseAgentRoomMessageV1,
  parseAgentRoomV1,
  sealAccountScopedBlobCiphertext,
  type AccountScopedCryptoMaterial,
  type AgentRoomMessageDraft,
  type AgentRoomMessageV1,
  type AgentRoomV1,
} from '@happier-dev/protocol';

import { ACCOUNT_KV_BULK_GET_MAX_KEYS, type AccountKvTransport } from '@/api/kv/accountKvHttpTransport';

/**
 * The account's rooms in the UserKVStore (kind `agent_room`, keys in `packages/protocol/src/rooms/agentRoom.ts`).
 * The app and the threads of every member write to a room at once, so each append re-reads the room
 * and tries again whenever another writer took the seq first.
 */
export class AgentRoomStore {
  constructor(private readonly deps: Readonly<{
    transport: AccountKvTransport;
    material: AccountScopedCryptoMaterial;
    now?: () => number;
    randomBytes?: (length: number) => Uint8Array;
  }>) {}

  async getRoom(roomId: string): Promise<Readonly<{ room: AgentRoomV1; version: number }> | null> {
    const [row] = await this.deps.transport.bulkGet([agentRoomKvKey(roomId)]);
    const room = row ? parseAgentRoomV1(this.open(row.value)) : null;
    return row && room ? { room, version: row.version } : null;
  }

  /**
   * Adds a message at the room's next seq (the room and the message in one atomic write); null when
   * the room doesn't exist. A conflict on the room means another writer changed it first (usually
   * taking that seq), so it is read again; the seq being taken while the room is unchanged can't be
   * fixed by retrying.
   */
  async appendMessage(roomId: string, draft: AgentRoomMessageDraft): Promise<AgentRoomMessageV1 | null> {
    const roomKey = agentRoomKvKey(roomId);
    for (;;) {
      const current = await this.getRoom(roomId);
      if (!current) return null;
      const next = appendRoomMessage(current.room, draft, this.now());
      const messageKey = agentRoomMessageKvKey(roomId, next.message.seq);
      const result = await this.deps.transport.mutate([
        { key: roomKey, value: this.seal(next.room), version: current.version },
        { key: messageKey, value: this.seal(next.message), version: -1 },
      ]);
      if (result.ok) return next.message;
      if (!result.current.some((row) => row.key === roomKey)) {
        throw new Error(`room ${roomId} already has a message at seq ${next.message.seq} past its last seq`);
      }
    }
  }

  /** The messages from `fromSeq` to `toSeq` (inclusive) that exist, oldest first. */
  async readMessages(roomId: string, range: Readonly<{ fromSeq: number; toSeq: number }>): Promise<AgentRoomMessageV1[]> {
    const keys: string[] = [];
    for (let seq = Math.max(1, range.fromSeq); seq <= range.toSeq; seq += 1) keys.push(agentRoomMessageKvKey(roomId, seq));
    const messages: AgentRoomMessageV1[] = [];
    for (let start = 0; start < keys.length; start += ACCOUNT_KV_BULK_GET_MAX_KEYS) {
      for (const row of await this.deps.transport.bulkGet(keys.slice(start, start + ACCOUNT_KV_BULK_GET_MAX_KEYS))) {
        const message = parseAgentRoomMessageV1(this.open(row.value));
        if (message && message.roomId === roomId) messages.push(message);
      }
    }
    return messages.sort((a, b) => a.seq - b.seq);
  }

  private open(ciphertext: string): unknown {
    return openAccountScopedBlobCiphertext({ kind: 'agent_room', material: this.deps.material, ciphertext })?.value ?? null;
  }

  private seal(payload: unknown): string {
    return sealAccountScopedBlobCiphertext({
      kind: 'agent_room',
      material: this.deps.material,
      payload,
      randomBytes: this.deps.randomBytes ?? ((length) => new Uint8Array(nodeRandomBytes(length))),
    });
  }

  private now(): number {
    return this.deps.now?.() ?? Date.now();
  }
}

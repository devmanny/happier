import { randomBytes as nodeRandomBytes } from 'node:crypto';

import {
  AGENT_ROOM_KV_PREFIX,
  agentRoomKvKey,
  agentRoomMessageKvKey,
  agentRoomSeatKvKey,
  appendRoomMessage,
  openAccountScopedBlobCiphertext,
  parseAgentRoomMessageV1,
  parseAgentRoomSeatV1,
  parseAgentRoomV1,
  resolveRoomReply,
  sealAccountScopedBlobCiphertext,
  type AccountScopedCryptoMaterial,
  type AgentRoomAuthor,
  type AgentRoomMessageDraft,
  type AgentRoomMessageV1,
  type AgentRoomSeatV1,
  type AgentRoomV1,
} from '@happier-dev/protocol';

import { ACCOUNT_KV_BULK_GET_MAX_KEYS, ACCOUNT_KV_LIST_MAX_ROWS, type AccountKvTransport } from '@/api/kv/accountKvHttpTransport';

/** A member's delivery as its seat records it. */
export type RoomDeliveryInFlight = NonNullable<AgentRoomSeatV1['inFlight']>;

/**
 * The account's rooms in the UserKVStore (kind `agent_room`, keys in `packages/protocol/src/rooms/agentRoom.ts`).
 * The app and the threads of every member write to a room at once, so each write re-reads what it
 * changes and tries again whenever another writer changed it first.
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

  /** Every room (`room/` rows only). The route has no cursor, so `complete` is false when the listing came back full. */
  async listRooms(): Promise<Readonly<{ rooms: AgentRoomV1[]; complete: boolean }>> {
    const rows = await this.deps.transport.list(AGENT_ROOM_KV_PREFIX);
    const rooms = rows.flatMap((row) => {
      const room = parseAgentRoomV1(this.open(row.value));
      return room && agentRoomKvKey(room.id) === row.key ? [room] : [];
    });
    return { rooms, complete: rows.length < ACCOUNT_KV_LIST_MAX_ROWS };
  }

  /** The seats of these members that exist, by agent id. */
  async getSeats(roomId: string, agentIds: readonly string[]): Promise<Map<string, Readonly<{ seat: AgentRoomSeatV1; version: number }>>> {
    const seats = new Map<string, Readonly<{ seat: AgentRoomSeatV1; version: number }>>();
    const keys = agentIds.map((agentId) => agentRoomSeatKvKey(roomId, agentId));
    for (const row of await this.bulkGet(keys)) {
      const seat = parseAgentRoomSeatV1(this.open(row.value));
      if (seat && seat.roomId === roomId && agentRoomSeatKvKey(roomId, seat.agentId) === row.key) {
        seats.set(seat.agentId, { seat, version: row.version });
      }
    }
    return seats;
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

  /**
   * Records that a delivery to the member started, if its seat is still at `current` (null: it has
   * no seat yet). False when another writer changed the seat first.
   */
  async startDelivery(
    roomId: string,
    agentId: string,
    delivery: Readonly<{ localId: string; throughSeq: number }>,
    current: Readonly<{ seat: AgentRoomSeatV1; version: number }> | null,
  ): Promise<boolean> {
    const now = this.now();
    const seat: AgentRoomSeatV1 = {
      ...(current?.seat ?? { v: 1 as const, roomId, agentId, readThroughSeq: 0 }),
      inFlight: { localId: delivery.localId, throughSeq: delivery.throughSeq, at: now },
      updatedAt: now,
    };
    const result = await this.deps.transport.mutate([
      { key: agentRoomSeatKvKey(roomId, agentId), value: this.seal(seat), version: current?.version ?? -1 },
    ]);
    return result.ok;
  }

  /** Applies `change` to the member's current seat; null when it has none. */
  async updateSeat(roomId: string, agentId: string, change: (seat: AgentRoomSeatV1, now: number) => AgentRoomSeatV1): Promise<AgentRoomSeatV1 | null> {
    const key = agentRoomSeatKvKey(roomId, agentId);
    for (;;) {
      const current = (await this.getSeats(roomId, [agentId])).get(agentId);
      if (!current) return null;
      const now = this.now();
      const next = { ...change(current.seat, now), updatedAt: now };
      const result = await this.deps.transport.mutate([{ key, value: this.seal(next), version: current.version }]);
      if (result.ok) return next;
    }
  }

  /**
   * Ends the member's turn for the delivery sent with `localId`, in one atomic write: its reply
   * (when it has text) is posted with the members and the user it mentions, its marker moves to what
   * that delivery read through (messages that came during the turn stay unread) and the delivery is
   * cleared. A delivery that is not in flight any more (already finished) changes nothing.
   */
  async finishTurn(params: Readonly<{
    roomId: string;
    agentId: string;
    localId: string;
    author: Extract<AgentRoomAuthor, { kind: 'agent' }>;
    text: string | null;
  }>): Promise<Readonly<{ finished: false }> | Readonly<{ finished: true; message: AgentRoomMessageV1 | null }>> {
    const roomKey = agentRoomKvKey(params.roomId);
    const seatKey = agentRoomSeatKvKey(params.roomId, params.agentId);
    for (;;) {
      const rows = await this.bulkGet([roomKey, seatKey]);
      const roomRow = rows.find((row) => row.key === roomKey);
      const seatRow = rows.find((row) => row.key === seatKey);
      const room = roomRow ? parseAgentRoomV1(this.open(roomRow.value)) : null;
      const seat = seatRow ? parseAgentRoomSeatV1(this.open(seatRow.value)) : null;
      if (!seatRow || !seat?.inFlight || seat.inFlight.localId !== params.localId) return { finished: false };

      const now = this.now();
      const { inFlight, ...rest } = seat;
      const mutations: Array<{ key: string; value: string; version: number }> = [{
        key: seatKey,
        value: this.seal({ ...rest, readThroughSeq: Math.max(seat.readThroughSeq, inFlight.throughSeq), updatedAt: now }),
        version: seatRow.version,
      }];
      const text = params.text?.trim();
      let message: AgentRoomMessageV1 | null = null;
      if (room && roomRow && text) {
        const next = appendRoomMessage(room, {
          author: params.author,
          text,
          ...resolveRoomReply({ room, agentId: params.agentId, text }),
        }, now);
        message = next.message;
        mutations.push(
          { key: roomKey, value: this.seal(next.room), version: roomRow.version },
          { key: agentRoomMessageKvKey(params.roomId, next.message.seq), value: this.seal(next.message), version: -1 },
        );
      }
      const result = await this.deps.transport.mutate(mutations);
      if (result.ok) return { finished: true, message };
      if (!result.current.some((row) => row.key === roomKey || row.key === seatKey)) {
        throw new Error(`room ${params.roomId} already has a message at seq ${message?.seq} past its last seq`);
      }
    }
  }

  /** The messages from `fromSeq` to `toSeq` (inclusive) that exist, oldest first. */
  async readMessages(roomId: string, range: Readonly<{ fromSeq: number; toSeq: number }>): Promise<AgentRoomMessageV1[]> {
    const seqs: number[] = [];
    for (let seq = Math.max(1, range.fromSeq); seq <= range.toSeq; seq += 1) seqs.push(seq);
    return this.readMessagesAt(roomId, seqs);
  }

  /** The messages at these seqs that exist, oldest first. */
  async readMessagesAt(roomId: string, seqs: readonly number[]): Promise<AgentRoomMessageV1[]> {
    const keys = seqs.map((seq) => agentRoomMessageKvKey(roomId, seq));
    const messages: AgentRoomMessageV1[] = [];
    for (const row of await this.bulkGet(keys)) {
      const message = parseAgentRoomMessageV1(this.open(row.value));
      if (message && message.roomId === roomId) messages.push(message);
    }
    return messages.sort((a, b) => a.seq - b.seq);
  }

  /** Exact keys over as many bulk reads as the route needs. */
  private async bulkGet(keys: readonly string[]): Promise<Array<Readonly<{ key: string; value: string; version: number }>>> {
    const rows: Array<Readonly<{ key: string; value: string; version: number }>> = [];
    for (let start = 0; start < keys.length; start += ACCOUNT_KV_BULK_GET_MAX_KEYS) {
      rows.push(...await this.deps.transport.bulkGet(keys.slice(start, start + ACCOUNT_KV_BULK_GET_MAX_KEYS)));
    }
    return rows;
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

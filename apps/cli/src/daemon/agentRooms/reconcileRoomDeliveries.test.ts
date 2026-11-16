import { describe, expect, it, vi } from 'vitest';

import {
  agentRoomKvKey,
  agentRoomMessageKvKey,
  agentRoomSeatKvKey,
  buildRoomDeliveryPrompt,
  sealAccountScopedBlobCiphertext,
  type AgentProfileV1,
  type AgentRoomV1,
} from '@happier-dev/protocol';

import type { AccountKvTransport } from '@/api/kv/accountKvHttpTransport';
import { createInMemoryAccountKv } from '@/api/kv/inMemoryAccountKv.testkit';
import { AgentRoomStore } from '@/session/agentRooms/agentRoomStore';
import type { TurnReply } from '@/session/services/readTurnReplyAfterLocalId';

import { reconcileRoomDeliveries, type RoomDeliveryDeps } from './reconcileRoomDeliveries';

const material = { type: 'dataKey', machineKey: new Uint8Array(32).fill(8) } as const;
const room: AgentRoomV1 = {
  v: 1, id: 'r1', title: 'App nueva', userName: 'Manny', lastSeq: 0, createdAt: 0, updatedAt: 0,
  members: [
    { agentId: 'a-mateo', name: 'Mateo', machineId: 'm1', directory: '/work/movil', wakeByAgents: true },
    { agentId: 'a-tomas', name: 'Tomás', machineId: 'm2', directory: '/work/escritorio' },
  ],
};
const mateoProfile: AgentProfileV1 = {
  v: 1, id: 'a-mateo', name: 'Mateo', providerId: 'codex', modelId: 'gpt-6', account: { label: 'ChatGPT Manny' }, updatedAt: 0,
};

async function setup(overrides: Partial<RoomDeliveryDeps> = {}) {
  const kv = createInMemoryAccountKv();
  await kv.transport.mutate([{ key: agentRoomKvKey('r1'), version: -1,
    value: sealAccountScopedBlobCiphertext({ kind: 'agent_room', material, payload: room, randomBytes: (n) => new Uint8Array(n) }) }]);
  // The relay boundary, with a hook that runs right after a read returns (what another writer does then).
  const relay: { afterRead?: (keys: readonly string[]) => Promise<void> } = {};
  const transport: AccountKvTransport = {
    ...kv.transport,
    bulkGet: async (keys) => {
      const rows = await kv.transport.bulkGet(keys);
      await relay.afterRead?.(keys);
      return rows;
    },
  };
  const store = new AgentRoomStore({ transport, material });
  let nonce = 0;
  const mocks = {
    startThread: vi.fn(async () => ({ ok: true as const, sessionId: 's-mateo' })),
    sendToThread: vi.fn(async (): Promise<{ ok: true } | { ok: false; code: string }> => ({ ok: true })),
    readTurnReply: vi.fn(async (): Promise<TurnReply | 'thread_gone' | null> => null),
  };
  const deps: RoomDeliveryDeps = {
    store,
    machineId: 'm1',
    readAgentProfile: async (agentId: string) => (agentId === 'a-mateo' ? mateoProfile : null),
    ...mocks,
    push: null,
    newNonce: () => `n${++nonce}`,
    ...overrides,
  };
  const seatOf = async (agentId: string) => (await store.getSeats('r1', [agentId])).get(agentId)?.seat ?? null;
  return { kv, relay, store, deps, mocks, seatOf };
}

const mateoAuthor = (sessionId: string) => ({ kind: 'agent' as const, agentId: 'a-mateo', name: 'Mateo', sessionId });

/** Mateo's thread `s-old` got #1 and answered it with #2; the user then mentions it again (#3). */
async function answeredOnceThenMentioned(store: AgentRoomStore) {
  await store.appendMessage('r1', { author: { kind: 'user' }, text: '@Mateo ¿cómo va el login?', mentions: ['a-mateo'] });
  await store.startDelivery('r1', 'a-mateo', { localId: 'room.r1.a-mateo.old', throughSeq: 1 }, null);
  await store.updateSeat('r1', 'a-mateo', (seat) => ({ ...seat, sessionId: 's-old', inFlight: { ...seat.inFlight!, sent: true } }));
  await store.finishTurn({ roomId: 'r1', agentId: 'a-mateo', localId: 'room.r1.a-mateo.old', author: mateoAuthor('s-old'), text: 'Va bien, falta el registro' });
  await store.appendMessage('r1', { author: { kind: 'user' }, text: '@Mateo ¿y el registro?', mentions: ['a-mateo'] });
}

describe('reconcileRoomDeliveries', () => {
  it('opens the mentioned member\'s thread in its folder, as its agent, with what it had not read', async () => {
    const { store, deps, mocks, seatOf } = await setup();
    await store.appendMessage('r1', { author: { kind: 'user' }, text: 'Hola a todos' });
    await store.appendMessage('r1', { author: { kind: 'user' }, text: '@Mateo ¿cómo va el login? @Tomás tú la app', mentions: ['a-mateo', 'a-tomas'] });

    await reconcileRoomDeliveries('r1', deps);

    expect(mocks.startThread).toHaveBeenCalledTimes(1);
    const [spawn, firstInput] = mocks.startThread.mock.calls[0] as unknown as [Record<string, unknown>, { text: string; localId: string }];
    expect(spawn).toMatchObject({
      directory: '/work/movil', backendTarget: { kind: 'builtInAgent', agentId: 'codex' }, modelId: 'gpt-6', permissionMode: 'yolo',
      agentIdentity: { id: 'a-mateo', name: 'Mateo' },
    });
    expect(firstInput.localId).toBe('room.r1.a-mateo.n1');
    expect(firstInput.text).toContain('[#1] Manny: Hola a todos\n\n[#2] Manny: @Mateo ¿cómo va el login? @Tomás tú la app');
    // Its first thread ever gets only what it hadn't read: there is nothing before to recap.
    const messages = await store.readMessages('r1', { fromSeq: 1, toSeq: 2 });
    expect(firstInput.text).toBe(buildRoomDeliveryPrompt({ room: { ...room, lastSeq: 2 }, member: room.members[0]!, messages, fromSeq: 1, toSeq: 2 }));
    expect(await seatOf('a-mateo')).toMatchObject({ sessionId: 's-mateo', readThroughSeq: 0, inFlight: { localId: 'room.r1.a-mateo.n1', throughSeq: 2, sent: true } });
    // Tomás works on another machine: its daemon delivers to it.
    expect(await seatOf('a-tomas')).toBeNull();
  });

  it('holds a mention while the member\'s turn runs, finishes that turn from its transcript, then delivers the rest', async () => {
    const { store, deps, mocks, seatOf } = await setup();
    await store.appendMessage('r1', { author: { kind: 'user' }, text: '@Mateo empieza', mentions: ['a-mateo'] });
    await reconcileRoomDeliveries('r1', deps);
    await store.appendMessage('r1', { author: { kind: 'user' }, text: '@Mateo y luego esto', mentions: ['a-mateo'] });

    mocks.readTurnReply.mockResolvedValue({ finished: false, text: 'a medias' });
    await reconcileRoomDeliveries('r1', deps);
    expect(mocks.sendToThread).not.toHaveBeenCalled();
    expect((await store.getRoom('r1'))!.room.lastSeq).toBe(2);

    mocks.readTurnReply.mockResolvedValue({ finished: true, text: 'Empecé. @Tomás revisa' });
    await reconcileRoomDeliveries('r1', deps);
    expect(mocks.readTurnReply).toHaveBeenLastCalledWith('s-mateo', 'room.r1.a-mateo.n1');
    const [reply] = await store.readMessages('r1', { fromSeq: 3, toSeq: 3 });
    expect(reply).toMatchObject({ text: 'Empecé. @Tomás revisa', mentions: ['a-tomas'], author: { kind: 'agent', agentId: 'a-mateo', sessionId: 's-mateo' } });
    expect(await seatOf('a-mateo')).toMatchObject({ readThroughSeq: 1 });

    await reconcileRoomDeliveries('r1', deps);
    expect(mocks.sendToThread).toHaveBeenCalledTimes(1);
    const [sessionId, text, localId, permissionMode] = mocks.sendToThread.mock.calls[0] as unknown as [string, string, string, string];
    expect([sessionId, localId, permissionMode]).toEqual(['s-mateo', 'room.r1.a-mateo.n2', 'yolo']);
    expect(text).toContain('[#2] Manny: @Mateo y luego esto');
    expect(text).not.toContain('[#3]');
  });

  it('quotes the message the user answered, even one from long before what the member had not read', async () => {
    const { store, deps, mocks } = await setup();
    await store.appendMessage('r1', { author: { kind: 'agent', agentId: 'a-mateo', name: 'Mateo' }, text: '¿Sigo con el registro\no con la recuperación?' });
    for (let index = 0; index < 8; index += 1) await store.appendMessage('r1', { author: { kind: 'user' }, text: `nota ${index + 2}` });
    await store.startDelivery('r1', 'a-mateo', { localId: 'room.r1.a-mateo.old', throughSeq: 9 }, null);
    await store.updateSeat('r1', 'a-mateo', ({ inFlight: _done, ...seat }) => ({ ...seat, sessionId: 's-mateo', readThroughSeq: 9 }));
    await store.appendMessage('r1', { author: { kind: 'user' }, text: 'Con el registro', mentions: ['a-mateo'], replyTo: { seq: 1 } });

    await reconcileRoomDeliveries('r1', deps);

    const [, text] = mocks.sendToThread.mock.calls[0] as unknown as [string, string];
    expect(text).toContain('[#10] Manny (answer to your #1: "¿Sigo con el registro o con la recuperación?"): Con el registro');
    expect(text).not.toContain('[#1] ');
  });

  it('retries a delivery that could not be sent with the same localId, and opens a new thread when the old one is gone', async () => {
    const sendToThread = vi.fn()
      .mockResolvedValueOnce({ ok: false, code: 'timeout' })
      .mockResolvedValueOnce({ ok: false, code: 'session_archived' });
    const { store, deps, mocks, seatOf } = await setup({ sendToThread });
    await store.startDelivery('r1', 'a-mateo', { localId: 'room.r1.a-mateo.old', throughSeq: 0 }, null);
    await store.updateSeat('r1', 'a-mateo', (seat) => ({ ...seat, sessionId: 's-old', inFlight: undefined }));
    await store.appendMessage('r1', { author: { kind: 'user' }, text: '@Mateo hola', mentions: ['a-mateo'] });

    await reconcileRoomDeliveries('r1', deps);
    expect(await seatOf('a-mateo')).toMatchObject({ sessionId: 's-old', inFlight: { localId: 'room.r1.a-mateo.n1' } });
    expect((await seatOf('a-mateo'))!.inFlight!.sent).toBeUndefined();

    await reconcileRoomDeliveries('r1', deps);
    expect(sendToThread.mock.calls.map((call) => call[2])).toEqual(['room.r1.a-mateo.n1', 'room.r1.a-mateo.n1']);
    expect(mocks.startThread).toHaveBeenCalledWith(expect.anything(), expect.objectContaining({ localId: 'room.r1.a-mateo.n1' }));
    expect(await seatOf('a-mateo')).toMatchObject({ sessionId: 's-mateo', inFlight: { sent: true } });
  });

  it('opens a new thread with the room so far, its own replies included, when the member\'s thread is gone', async () => {
    const sendToThread = vi.fn(async (): Promise<{ ok: true } | { ok: false; code: string }> => ({ ok: false, code: 'session_archived' }));
    const { store, deps, mocks, seatOf } = await setup({ sendToThread });
    await answeredOnceThenMentioned(store);

    await reconcileRoomDeliveries('r1', deps);

    expect(sendToThread).toHaveBeenCalledWith('s-old', expect.any(String), 'room.r1.a-mateo.n1', 'yolo');
    const [, firstInput] = mocks.startThread.mock.calls[0] as unknown as [unknown, { text: string; localId: string }];
    expect(firstInput.localId).toBe('room.r1.a-mateo.n1');
    expect(firstInput.text).toContain('[#1] Manny: @Mateo ¿cómo va el login?\n\n[#2] Mateo: Va bien, falta el registro');
    expect(firstInput.text).toContain('[#3] Manny: @Mateo ¿y el registro?');
    expect(firstInput.text).toContain('s-old');
    expect(await seatOf('a-mateo')).toMatchObject({ sessionId: 's-mateo', readThroughSeq: 1, inFlight: { localId: 'room.r1.a-mateo.n1', throughSeq: 3, sent: true } });
  });

  it('re-delivers a turn whose thread was archived or deleted mid-turn to a new thread, leaving the marker where it was', async () => {
    const { store, deps, mocks, seatOf } = await setup();
    await answeredOnceThenMentioned(store);
    const current = (await store.getSeats('r1', ['a-mateo'])).get('a-mateo')!;
    await store.startDelivery('r1', 'a-mateo', { localId: 'room.r1.a-mateo.mid', throughSeq: 3 }, current);
    await store.updateSeat('r1', 'a-mateo', (seat) => ({ ...seat, inFlight: { ...seat.inFlight!, sent: true } }));
    mocks.readTurnReply.mockResolvedValue('thread_gone');

    await reconcileRoomDeliveries('r1', deps);

    expect(mocks.readTurnReply).toHaveBeenCalledWith('s-old', 'room.r1.a-mateo.mid');
    expect(mocks.sendToThread).not.toHaveBeenCalled();
    expect(mocks.startThread).toHaveBeenCalledTimes(1);
    const [, firstInput] = mocks.startThread.mock.calls[0] as unknown as [unknown, { text: string; localId: string }];
    // A new localId: a late reply of the old thread can't finish this delivery.
    expect(firstInput.localId).toBe('room.r1.a-mateo.n1');
    expect(firstInput.text).toContain('[#2] Mateo: Va bien, falta el registro');
    expect(firstInput.text).toContain('[#3] Manny: @Mateo ¿y el registro?');
    expect(firstInput.text).toContain('s-old');
    expect(await seatOf('a-mateo')).toMatchObject({ sessionId: 's-mateo', readThroughSeq: 1, inFlight: { localId: 'room.r1.a-mateo.n1', throughSeq: 3, sent: true } });
    expect((await store.getRoom('r1'))!.room.lastSeq).toBe(3);
  });

  it('sends nothing when the user withdraws a message between its read and the claim, and delivers without it next time', async () => {
    // What the app's withdraw relies on: seats are read before messages, and the claim is a CAS on that seat's version.
    const { kv, relay, store, deps, mocks } = await setup();
    await store.appendMessage('r1', { author: { kind: 'user' }, text: '@Mateo hola', mentions: ['a-mateo'] });
    await store.startDelivery('r1', 'a-mateo', { localId: 'room.r1.a-mateo.old', throughSeq: 1 }, null);
    await store.updateSeat('r1', 'a-mateo', ({ inFlight: _done, ...seat }) => ({ ...seat, sessionId: 's-mateo', readThroughSeq: 1 }));
    await store.appendMessage('r1', { author: { kind: 'user' }, text: '@Mateo borra la base de producción', mentions: ['a-mateo'] });
    await store.appendMessage('r1', { author: { kind: 'user' }, text: '@Mateo mejor corre los tests', mentions: ['a-mateo'] });

    const withdrawn = agentRoomMessageKvKey('r1', 2);
    const seatKey = agentRoomSeatKvKey('r1', 'a-mateo');
    relay.afterRead = async (keys) => {
      if (!keys.includes(withdrawn)) return;
      relay.afterRead = undefined;
      // The app: the message deleted and the seat written back byte for byte, in one atomic write.
      const message = kv.rows.get(withdrawn)!;
      const seat = kv.rows.get(seatKey)!;
      expect(await kv.transport.mutate([
        { key: withdrawn, value: null, version: message.version },
        { key: seatKey, value: seat.value, version: seat.version },
      ])).toMatchObject({ ok: true });
    };

    await reconcileRoomDeliveries('r1', deps);
    expect(relay.afterRead).toBeUndefined();
    expect(mocks.sendToThread).not.toHaveBeenCalled();
    expect(mocks.startThread).not.toHaveBeenCalled();
    expect((await store.getSeats('r1', ['a-mateo'])).get('a-mateo')!.seat.inFlight).toBeUndefined();

    await reconcileRoomDeliveries('r1', deps);
    expect(mocks.sendToThread).toHaveBeenCalledTimes(1);
    const [, text] = mocks.sendToThread.mock.calls[0] as unknown as [string, string];
    expect(text).toContain('[#3] Manny: @Mateo mejor corre los tests');
    expect(text).not.toContain('borra la base');
  });
});

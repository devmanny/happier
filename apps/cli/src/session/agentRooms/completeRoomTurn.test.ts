import { afterEach, describe, expect, it, vi } from 'vitest';

import { AGENT_ROOM_MAX_AGENT_TURNS, accountSettingsParse, agentRoomKvKey, sealAccountScopedBlobCiphertext, type AgentRoomV1 } from '@happier-dev/protocol';

import { createInMemoryAccountKv } from '@/api/kv/inMemoryAccountKv.testkit';
import { resetSessionNotificationMuteForTests, trackSessionNotificationMute } from '@/session/notifications/sessionNotificationMute';
import { readTurnReplyFromRows, type TurnReply } from '@/session/services/readTurnReplyAfterLocalId';
import { resetActiveAccountSettingsSnapshotForTests, setActiveAccountSettingsSnapshot } from '@/settings/accountSettings/activeAccountSettingsSnapshot';

import { AgentRoomStore } from './agentRoomStore';
import { completeRoomTurn, settleRoomTurn } from './completeRoomTurn';

const material = { type: 'dataKey', machineKey: new Uint8Array(32).fill(3) } as const;
const room: AgentRoomV1 = {
  v: 1, id: 'r1', title: 'App nueva', userName: 'Manny', lastSeq: 0, createdAt: 0, updatedAt: 0,
  members: [
    { agentId: 'a-mateo', name: 'Mateo', machineId: 'm1', directory: '/w1', wakeByAgents: true },
    { agentId: 'a-tomas', name: 'Tomás', machineId: 'm2', directory: '/w2', wakeByAgents: true },
  ],
};
const mateo = { kind: 'agent' as const, agentId: 'a-mateo', name: 'Mateo' };
const tomas = { kind: 'agent' as const, agentId: 'a-tomas', name: 'Tomás' };

async function setup(payload: AgentRoomV1 = room) {
  const kv = createInMemoryAccountKv();
  await kv.transport.mutate([{ key: agentRoomKvKey(payload.id), version: -1,
    value: sealAccountScopedBlobCiphertext({ kind: 'agent_room', material, payload, randomBytes: (n) => new Uint8Array(n) }) }]);
  return new AgentRoomStore({ transport: kv.transport, material });
}

/** The account's notification settings, as the active snapshot holds them. */
function useSettings(notificationsSettingsV1: Record<string, unknown>) {
  setActiveAccountSettingsSnapshot({
    source: 'network', settings: accountSettingsParse({ notificationsSettingsV1: { v: 1, ...notificationsSettingsV1 } }),
    settingsVersion: 1, loadedAtMs: 0, settingsSecretsReadKeys: [],
  });
}

afterEach(() => {
  resetActiveAccountSettingsSnapshotForTests();
  resetSessionNotificationMuteForTests();
});

describe('completeRoomTurn', () => {
  it('tells the user when a hand-off reaches the brake', async () => {
    const store = await setup();
    await store.appendMessage('r1', { author: { kind: 'user' }, text: '@Mateo @Tomás platiquen', mentions: ['a-mateo', 'a-tomas'] });
    for (let turn = 1; turn < AGENT_ROOM_MAX_AGENT_TURNS; turn += 1) {
      await store.appendMessage('r1', turn % 2 ? { author: tomas, text: '@Mateo', mentions: ['a-mateo'] } : { author: mateo, text: '@Tomás', mentions: ['a-tomas'] });
    }
    const lastSeq = (await store.getRoom('r1'))!.room.lastSeq;
    await store.startDelivery('r1', 'a-mateo', { localId: 'room.r1.a-mateo.n', throughSeq: lastSeq }, null);
    const push = { sendToAllDevicesAsync: vi.fn(async () => {}) };

    const outcome = await completeRoomTurn({
      store, delivery: { roomId: 'r1', agentId: 'a-mateo', localId: 'room.r1.a-mateo.n' }, author: mateo,
      reply: { finished: true, text: 'Te toca, @Tomás' }, push,
    });

    expect(outcome).toBe('finished');
    // The reply's own notice, then the brake's.
    expect(push.sendToAllDevicesAsync).toHaveBeenCalledTimes(2);
    expect(push.sendToAllDevicesAsync).toHaveBeenLastCalledWith('Room on hold', expect.stringContaining('App nueva'), { type: 'room_brake', roomId: 'r1', seq: lastSeq + 1 });
  });

  it('leaves a turn that has not finished, and pushes nothing when the user turned pushes off', async () => {
    const store = await setup();
    await store.startDelivery('r1', 'a-mateo', { localId: 'room.r1.a-mateo.n', throughSeq: 0 }, null);
    const push = { sendToAllDevicesAsync: vi.fn(async () => {}) };
    const delivery = { roomId: 'r1', agentId: 'a-mateo', localId: 'room.r1.a-mateo.n' };

    expect(await completeRoomTurn({ store, delivery, author: mateo, reply: { finished: false, text: 'a medias' }, push }))
      .toBe('running');
    useSettings({ pushEnabled: false });
    expect(await completeRoomTurn({ store, delivery, author: mateo, reply: { finished: true, text: '@Manny listo' }, push }))
      .toBe('finished');
    expect(push.sendToAllDevicesAsync).not.toHaveBeenCalled();
  });

  it('in an agent\'s own chat, pushes every reply as Messages does: its name, the reply without its cards or options, and the chat', async () => {
    const direct: AgentRoomV1 = { ...room, id: 'direct-a-mateo', kind: 'direct', title: 'Mateo', members: [room.members[0]!] };
    const store = await setup(direct);
    const push = { sendToAllDevicesAsync: vi.fn(async () => {}) };
    const finish = async (localId: string, text: string) => {
      await store.appendMessage('direct-a-mateo', { author: { kind: 'user' }, text: '¿Qué haces?', mentions: ['a-mateo'] });
      const lastSeq = (await store.getRoom('direct-a-mateo'))!.room.lastSeq;
      await store.startDelivery('direct-a-mateo', 'a-mateo', { localId, throughSeq: lastSeq }, (await store.getSeats('direct-a-mateo', ['a-mateo'])).get('a-mateo') ?? null);
      return completeRoomTurn({
        store, delivery: { roomId: 'direct-a-mateo', agentId: 'a-mateo', localId }, author: { ...mateo, emoji: '🤖' },
        reply: { finished: true, text }, push,
      });
    };

    expect(await finish('room.direct-a-mateo.a-mateo.n1', 'Ando en dos sesiones:\n<session>cmabc1</session>\n<session>cmabc2</session>\nY **reviso** el login.')).toBe('finished');
    expect(push.sendToAllDevicesAsync).toHaveBeenLastCalledWith('Mateo 🤖', 'Ando en dos sesiones: Y reviso el login.', { type: 'room_mention', roomId: 'direct-a-mateo', seq: 2 });

    // One push even when the reply mentions the user.
    await finish('room.direct-a-mateo.a-mateo.n2', '@Manny ¿sigo con el registro?\n<options>\n<option>Sí</option>\n</options>');
    expect(push.sendToAllDevicesAsync).toHaveBeenCalledTimes(2);
    expect(push.sendToAllDevicesAsync).toHaveBeenLastCalledWith('Mateo 🤖', '@Manny ¿sigo con el registro?', { type: 'room_mention', roomId: 'direct-a-mateo', seq: 4 });
  });

  it('in an agent\'s own chat, pushes a reply under the settings of the turn-finished push it stands for', async () => {
    const direct: AgentRoomV1 = { ...room, id: 'direct-a-mateo', kind: 'direct', title: 'Mateo', members: [room.members[0]!] };
    const store = await setup(direct);
    const push = { sendToAllDevicesAsync: vi.fn(async () => {}) };
    const finish = async (localId: string) => {
      await store.appendMessage('direct-a-mateo', { author: { kind: 'user' }, text: '¿Qué haces?', mentions: ['a-mateo'] });
      const lastSeq = (await store.getRoom('direct-a-mateo'))!.room.lastSeq;
      await store.startDelivery('direct-a-mateo', 'a-mateo', { localId, throughSeq: lastSeq }, (await store.getSeats('direct-a-mateo', ['a-mateo'])).get('a-mateo') ?? null);
      return completeRoomTurn({
        store, delivery: { roomId: 'direct-a-mateo', agentId: 'a-mateo', localId }, author: { ...mateo, emoji: '🤖', sessionId: 'seat-1' },
        reply: { finished: true, text: 'Reviso el login.' }, push,
      });
    };

    // Reply text kept off the lock screen, and quiet while a computer is in use.
    useSettings({ readyIncludeMessageText: false, mutePhoneWhenComputerFocused: true });
    expect(await finish('room.direct-a-mateo.a-mateo.n1')).toBe('finished');
    expect(push.sendToAllDevicesAsync).toHaveBeenCalledWith('Mateo 🤖', 'New message', { type: 'room_mention', roomId: 'direct-a-mateo', seq: 2 }, { suppressIfComputerFocused: true });

    // Finished notifications off: no reply push either.
    useSettings({ ready: false });
    expect(await finish('room.direct-a-mateo.a-mateo.n2')).toBe('finished');
    // The thread's bell is off: no push.
    useSettings({});
    trackSessionNotificationMute({ sessionId: 'seat-1', getMetadataSnapshot: () => ({ notificationsMutedV1: { v: 1, muted: true, updatedAt: 0 } }) });
    expect(await finish('room.direct-a-mateo.a-mateo.n3')).toBe('finished');
    expect(push.sendToAllDevicesAsync).toHaveBeenCalledTimes(1);
  });

  it('in a room, pushes every reply once: a mention when it mentions the user, else the reply with the room\'s title', async () => {
    const store = await setup();
    const push = { sendToAllDevicesAsync: vi.fn(async () => {}) };
    const finish = async (localId: string, text: string) => {
      await store.appendMessage('r1', { author: { kind: 'user' }, text: '@Mateo ¿cómo vas?', mentions: ['a-mateo'] });
      const lastSeq = (await store.getRoom('r1'))!.room.lastSeq;
      await store.startDelivery('r1', 'a-mateo', { localId, throughSeq: lastSeq }, (await store.getSeats('r1', ['a-mateo'])).get('a-mateo') ?? null);
      await completeRoomTurn({ store, delivery: { roomId: 'r1', agentId: 'a-mateo', localId }, author: mateo, reply: { finished: true, text }, push });
    };

    await finish('room.r1.a-mateo.n1', 'Voy bien.');
    expect(push.sendToAllDevicesAsync).toHaveBeenLastCalledWith('Mateo', 'App nueva: Voy bien.', { type: 'room_mention', roomId: 'r1', seq: 2 });
    await finish('room.r1.a-mateo.n2', '@Manny ¿lo subo?');
    expect(push.sendToAllDevicesAsync).toHaveBeenLastCalledWith('Mateo mentioned you', 'App nueva: @Manny ¿lo subo?', { type: 'room_mention', roomId: 'r1', seq: 4 });
    expect(push.sendToAllDevicesAsync).toHaveBeenCalledTimes(2);
  });
});

describe('settleRoomTurn', () => {
  const n1 = 'room.r1.a-mateo.n1';
  const n2 = 'room.r1.a-mateo.n2';

  /** Mateo's thread s1 got #1 (n1) and, while it worked, a Steer Now of #2 (n2); or only n1 (`steered: false`). */
  async function chain(replies: Readonly<Record<string, TurnReply | null>>, steered = true) {
    const store = await setup();
    await store.appendMessage('r1', { author: { kind: 'user' }, text: '@Mateo revisa el login', mentions: ['a-mateo'] });
    await store.appendMessage('r1', { author: { kind: 'user' }, text: '@Mateo y el registro', mentions: ['a-mateo'] });
    await store.startDelivery('r1', 'a-mateo', { localId: n1, throughSeq: steered ? 1 : 2 }, null);
    await store.updateSeat('r1', 'a-mateo', (seat) => ({ ...seat, sessionId: 's1', inFlight: { ...seat.inFlight!, sent: true } }));
    if (steered) {
      const read = (await store.getSeats('r1', ['a-mateo'])).get('a-mateo')!;
      await store.startDelivery('r1', 'a-mateo', { localId: n2, throughSeq: 2, steers: { localId: n1, throughSeq: 1 } }, read);
      await store.updateSeat('r1', 'a-mateo', (seat) => ({ ...seat, inFlight: { ...seat.inFlight!, sent: true } }));
    }
    const seat = async () => (await store.getSeats('r1', ['a-mateo'])).get('a-mateo')!;
    const posted = async () => (await store.readMessages('r1', { fromSeq: 3, toSeq: 10 })).map((message) => message.text);
    const settle = async (turnEnded: boolean) => settleRoomTurn({
      store, delivery: { roomId: 'r1', agentId: 'a-mateo' }, inFlight: (await seat()).seat.inFlight!, sessionId: 's1',
      author: { ...mateo, sessionId: 's1' }, readTurnReply: async (_sessionId, localId) => replies[localId] ?? null, push: null, turnEnded,
    });
    return { seat, posted, settle };
  }

  it('posts one reply, the one after the Steer Now, when the steer joined the running turn', async () => {
    const merged = await chain({ [n1]: { finished: false, text: 'Reviso' }, [n2]: { finished: true, text: 'Listo con las dos' } });
    expect(await merged.settle(false)).toEqual({ turn: 'finished', replied: true });
    expect(await merged.posted()).toEqual(['Listo con las dos']);
    expect((await merged.seat()).seat).toMatchObject({ readThroughSeq: 2 });
    expect((await merged.seat()).seat.inFlight).toBeUndefined();
  });

  it('posts the reply of a turn that ended before the Steer Now reached it, and keeps the Steer Now', async () => {
    const missed = await chain({ [n1]: { finished: true, text: 'A' } });
    expect(await missed.settle(false)).toEqual({ turn: 'not_started', replied: true });
    expect(await missed.posted()).toEqual(['A']);
    expect((await missed.seat()).seat).toMatchObject({ readThroughSeq: 1, inFlight: { localId: n2, throughSeq: 2, sent: true } });
    // Until that turn's ready, which then knows the turn that ended was that one.
    expect((await missed.seat()).seat.inFlight!.steers).toEqual({ localId: n1, throughSeq: 1, ended: true });

    // At a ready the Steer Now's own turn may have only just begun: it is not posted early.
    const begun = await chain({ [n1]: { finished: true, text: 'A' }, [n2]: { finished: false, text: null } });
    expect(await begun.settle(true)).toEqual({ turn: 'running', replied: true });
    expect(await begun.posted()).toEqual(['A']);
    expect((await begun.seat()).seat).toMatchObject({ readThroughSeq: 1, inFlight: { localId: n2 } });
    expect((await begun.seat()).seat.inFlight!.steers).toBeUndefined();
  });

  it('at the ready of a turn already ended from the transcript, neither posts it again nor ends the Steer Now', async () => {
    const replies: Record<string, TurnReply | null> = { [n1]: { finished: true, text: 'A' }, [n2]: { finished: false, text: 'B parcial' } };
    const ended = await chain(replies);
    expect(await ended.settle(false)).toEqual({ turn: 'running', replied: true });
    expect(await ended.posted()).toEqual(['A']);

    // That turn's ready: the room told the user about it.
    expect(await ended.settle(true)).toEqual({ turn: 'running', replied: true });
    expect(await ended.posted()).toEqual(['A']);
    expect((await ended.seat()).seat).toMatchObject({ readThroughSeq: 1, inFlight: { localId: n2 } });
    expect((await ended.seat()).seat.inFlight!.steers).toBeUndefined();

    // The Steer Now's own ready ends it, even without a completion marker.
    expect(await ended.settle(true)).toEqual({ turn: 'finished', replied: true });
    expect(await ended.posted()).toEqual(['A', 'B parcial']);
    expect((await ended.seat()).seat.inFlight).toBeUndefined();
  });

  it('at a ready, ends the turn that ready ended even without a completion marker', async () => {
    // One delivery, as before Steer Now.
    const single = await chain({ [n1]: { finished: false, text: 'x' } }, false);
    expect(await single.settle(true)).toEqual({ turn: 'finished', replied: true });
    expect(await single.posted()).toEqual(['x']);
    expect((await single.seat()).seat.inFlight).toBeUndefined();

    // The Steer Now not in the transcript yet: that ready ended the turn it was sent past.
    const waiting = await chain({ [n1]: { finished: false, text: 'A parcial' } });
    expect(await waiting.settle(true)).toEqual({ turn: 'not_started', replied: true });
    expect(await waiting.posted()).toEqual(['A parcial']);
    expect((await waiting.seat()).seat).toMatchObject({ readThroughSeq: 1, inFlight: { localId: n2, sent: true } });
  });

  // Mateo's thread s1 as Codex app-server commits it, read the way the runner reads it. A Steer Now
  // that missed the turn ran as the next turn, after that turn's end; one that joined the turn has
  // no end before it. Both read the same at that ready (no ready between the two turns).
  it('posts both replies when the Steer Now ran as the next turn, and only the second when it joined the turn', async () => {
    const ctx = { encryptionKey: new Uint8Array([1]), encryptionVariant: 'legacy' as const };
    let seq = 0;
    const row = (v: unknown) => ({ seq: ++seq, createdAt: seq, content: { t: 'plain' as const, v } });
    const agent = (content: unknown) => row({ role: 'agent', content, meta: { sentFrom: 'cli', source: 'cli' } });
    const message = (text: string) => agent({ type: 'acp', provider: 'codex', data: { type: 'message', message: text } });
    const tool = () => agent({ type: 'codex', data: { type: 'tool-call', callId: `call-${seq}`, id: `item-${seq}`, name: 'exec', input: {} } });
    const turnEnd = () => agent({ type: 'acp', provider: 'codex', data: { type: 'task_complete', id: `turn-${seq}` } });
    const user = (localId: string) => ({ ...row({ role: 'user', content: { type: 'text', text: localId }, meta: {} }), localId });
    const ready = () => row({ role: 'agent', content: { id: `ready-${seq}`, type: 'event', data: { type: 'ready' } } });
    /** What `readTurnReplyAfterLocalId` reads: the rows after that user message. */
    const replies = (rows: ReadonlyArray<ReturnType<typeof row> & { localId?: string }>) => Object.fromEntries([n1, n2].map((localId) => {
      const at = rows.findIndex((entry) => entry.localId === localId);
      return [localId, at < 0 ? null : readTurnReplyFromRows({ rows: rows.slice(at + 1), ctx })];
    }));

    const drained = await chain(replies([user(n1), message('Reviso el login.'), tool(), message('Login listo.'), turnEnd(), user(n2), message('Registro listo.'), turnEnd(), ready()]));
    expect(await drained.settle(true)).toEqual({ turn: 'finished', replied: true });
    expect(await drained.posted()).toEqual(['Login listo.', 'Registro listo.']);
    expect((await drained.seat()).seat.inFlight).toBeUndefined();

    const merged = await chain(replies([user(n1), message('Reviso el login.'), tool(), user(n2), message('Login y registro listos.'), turnEnd(), ready()]));
    expect(await merged.settle(true)).toEqual({ turn: 'finished', replied: true });
    expect(await merged.posted()).toEqual(['Login y registro listos.']);
    expect((await merged.seat()).seat.inFlight).toBeUndefined();
  });

  // A goal continuation Codex starts itself after the room's turn ended writes no user message: a
  // room post while it runs must not take its commentary for the room turn's reply.
  it('posts the reply of the turn that ended, not what a turn the agent started itself after it writes', async () => {
    const ctx = { encryptionKey: new Uint8Array([1]), encryptionVariant: 'legacy' as const };
    let seq = 0;
    const row = (v: unknown) => ({ seq: ++seq, createdAt: seq, content: { t: 'plain' as const, v } });
    const agent = (content: unknown) => row({ role: 'agent', content, meta: { sentFrom: 'cli', source: 'cli' } });
    const message = (text: string) => agent({ type: 'acp', provider: 'codex', data: { type: 'message', message: text } });
    const tool = () => agent({ type: 'codex', data: { type: 'tool-call', callId: `call-${seq}`, id: `item-${seq}`, name: 'exec', input: {} } });
    const turnEnd = () => agent({ type: 'acp', provider: 'codex', data: { type: 'task_complete', id: `turn-${seq}` } });
    const rows = [message('Reviso.'), tool(), message('Listo turno 1.'), turnEnd(), message('Sigo con la meta: reviso el registro.'), tool()];

    const single = await chain({ [n1]: readTurnReplyFromRows({ rows, ctx }) }, false);
    expect(await single.settle(false)).toEqual({ turn: 'finished', replied: true });
    expect(await single.posted()).toEqual(['Listo turno 1.']);
    expect((await single.seat()).seat.inFlight).toBeUndefined();
  });

  it('changes nothing while both turns run', async () => {
    const running = await chain({ [n1]: { finished: false, text: 'Reviso' }, [n2]: { finished: false, text: 'Y el registro' } });
    const before = await running.seat();
    expect(await running.settle(false)).toEqual({ turn: 'running', replied: false });
    expect(await running.seat()).toEqual(before);
    expect(await running.posted()).toEqual([]);
  });
});

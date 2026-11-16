import { EventEmitter } from 'node:events';

import { afterEach, describe, expect, it, vi } from 'vitest';

import { agentRoomKvKey, sealAccountScopedBlobCiphertext, type AgentRoomV1 } from '@happier-dev/protocol';

import { createInMemoryAccountKv } from '@/api/kv/inMemoryAccountKv.testkit';
import { reconcileRoomDeliveries } from '@/daemon/agentRooms/reconcileRoomDeliveries';
import type { TurnReply } from '@/session/services/readTurnReplyAfterLocalId';

import { notifyRoomTurnReady, resetAgentRoomsForTests, startAgentRooms } from './startAgentRooms';

const machineKey = new Uint8Array(32).fill(2);
const credentials = { token: 't', encryption: { type: 'dataKey' as const, publicKey: new Uint8Array(32), machineKey } };
const material = { type: 'dataKey' as const, machineKey };
const env = { HAPPIER_AGENT_IDENTITY_JSON: JSON.stringify({ v: 1, id: 'a-mateo', name: 'Mateo', emoji: '🤖' }) };
const room: AgentRoomV1 = {
  v: 1, id: 'r1', title: 'App nueva', userName: 'Manny', lastSeq: 0, createdAt: 0, updatedAt: 0,
  members: [
    { agentId: 'a-mateo', name: 'Mateo', machineId: 'm1', directory: '/w1' },
    { agentId: 'a-tomas', name: 'Tomás', machineId: 'm2', directory: '/w2' },
  ],
};

afterEach(() => resetAgentRoomsForTests());

async function setup(readTurnReply: (sessionId: string, localId: string) => Promise<TurnReply | 'thread_gone' | null>) {
  const kv = createInMemoryAccountKv();
  await kv.transport.mutate([{ key: agentRoomKvKey('r1'), version: -1,
    value: sealAccountScopedBlobCiphertext({ kind: 'agent_room', material, payload: room, randomBytes: (n) => new Uint8Array(n) }) }]);
  const push = { sendToAllDevicesAsync: vi.fn(async () => {}) };
  const session = Object.assign(new EventEmitter(), { sessionId: 's1' });
  const rooms = startAgentRooms(session, credentials, { transport: kv.transport, env, readTurnReply, push })!;
  await rooms.store.appendMessage('r1', { author: { kind: 'user' }, text: '@Mateo ¿cómo vas?', mentions: ['a-mateo'] });
  await rooms.store.startDelivery('r1', 'a-mateo', { localId: 'room.r1.a-mateo.n1', throughSeq: 1 }, null);
  return { rooms, session, push };
}

describe('startAgentRooms', () => {
  it('posts the final text of a room turn as the agent\'s reply when the turn is ready, and moves its marker', async () => {
    const readTurnReply = vi.fn(async () => ({ finished: true, text: 'Voy bien. @Manny ¿lo subo?' }));
    const { rooms, session, push } = await setup(readTurnReply);

    session.emit('provider-input-delivered', { localId: 'room.r1.a-mateo.n1' });
    // The room took over the turn's notice.
    expect(await notifyRoomTurnReady('s1')).toBe(true);

    expect(readTurnReply).toHaveBeenCalledWith('s1', 'room.r1.a-mateo.n1');
    const [reply] = await rooms.store.readMessages('r1', { fromSeq: 2, toSeq: 2 });
    expect(reply).toMatchObject({
      text: 'Voy bien. @Manny ¿lo subo?', mentionsUser: true,
      author: { kind: 'agent', agentId: 'a-mateo', name: 'Mateo', emoji: '🤖', sessionId: 's1' },
    });
    const seat = (await rooms.store.getSeats('r1', ['a-mateo'])).get('a-mateo')!.seat;
    expect(seat).toMatchObject({ readThroughSeq: 1 });
    expect(seat.inFlight).toBeUndefined();
    expect(push.sendToAllDevicesAsync).toHaveBeenCalledWith('Mateo 🤖 mentioned you', 'App nueva: Voy bien. @Manny ¿lo subo?', { type: 'room_mention', roomId: 'r1', seq: 2 });
  });

  it('leaves turns that did not come from a room alone', async () => {
    const readTurnReply = vi.fn(async () => ({ finished: true, text: 'otra cosa' }));
    const { rooms, session } = await setup(readTurnReply);

    session.emit('provider-input-delivered', { localId: 'ui-typed-1' });
    expect(notifyRoomTurnReady('s1')).toBeNull();

    expect(readTurnReply).not.toHaveBeenCalled();
    expect((await rooms.store.getRoom('r1'))!.room.lastSeq).toBe(1);
  });

  it('leaves a turn whose thread is gone to the daemon, which delivers it again to a new thread', async () => {
    const readTurnReply = vi.fn(async () => 'thread_gone' as const);
    const { rooms, session, push } = await setup(readTurnReply);

    session.emit('provider-input-delivered', { localId: 'room.r1.a-mateo.n1' });
    await notifyRoomTurnReady('s1');

    expect(readTurnReply).toHaveBeenCalledWith('s1', 'room.r1.a-mateo.n1');
    expect((await rooms.store.getRoom('r1'))!.room.lastSeq).toBe(1);
    expect((await rooms.store.getSeats('r1', ['a-mateo'])).get('a-mateo')!.seat).toMatchObject({ readThroughSeq: 0, inFlight: { localId: 'room.r1.a-mateo.n1' } });
    expect(push.sendToAllDevicesAsync).not.toHaveBeenCalled();
  });

  it('leaves the turn\'s own notice to the ready when the turn ends without a final text: the room posts nothing', async () => {
    const readTurnReply = vi.fn(async () => ({ finished: true, text: null }));
    const { rooms, session, push } = await setup(readTurnReply);

    session.emit('provider-input-delivered', { localId: 'room.r1.a-mateo.n1' });
    expect(await notifyRoomTurnReady('s1')).toBe(false);

    // The turn is over in the room all the same.
    expect((await rooms.store.getRoom('r1'))!.room.lastSeq).toBe(1);
    const seat = (await rooms.store.getSeats('r1', ['a-mateo'])).get('a-mateo')!.seat;
    expect(seat).toMatchObject({ readThroughSeq: 1 });
    expect(seat.inFlight).toBeUndefined();
    expect(push.sendToAllDevicesAsync).not.toHaveBeenCalled();
  });

  describe('with a Steer Now sent past the delivery its turn was working', () => {
    const n1 = 'room.r1.a-mateo.n1';
    const n2 = 'room.r1.a-mateo.n2';

    /** Thread s1 got #1 (n1); the user sent #2 now (n2). `replies` is the transcript, changed between readies. */
    async function steered(replies: Record<string, TurnReply | null>) {
      const { rooms, session, push } = await setup(async (_sessionId, localId) => replies[localId] ?? null);
      await rooms.store.appendMessage('r1', { author: { kind: 'user' }, text: '@Mateo y el registro', mentions: ['a-mateo'] });
      await rooms.store.updateSeat('r1', 'a-mateo', (seat) => ({ ...seat, sessionId: 's1', inFlight: { ...seat.inFlight!, sent: true } }));
      const read = (await rooms.store.getSeats('r1', ['a-mateo'])).get('a-mateo')!;
      await rooms.store.startDelivery('r1', 'a-mateo', { localId: n2, throughSeq: 2, steers: { localId: n1, throughSeq: 1 } }, read);
      await rooms.store.updateSeat('r1', 'a-mateo', (seat) => ({ ...seat, inFlight: { ...seat.inFlight!, sent: true } }));
      session.emit('provider-input-delivered', { localId: n1 });
      session.emit('provider-input-delivered', { localId: n2 });
      const posted = async () => (await rooms.store.readMessages('r1', { fromSeq: 3, toSeq: 10 })).map((message) => message.text);
      const seat = async () => (await rooms.store.getSeats('r1', ['a-mateo'])).get('a-mateo')!.seat;
      // A run of the member's daemon on a room write (the Steer Now's own claim and `sent` writes each start one).
      const daemonRun = () => reconcileRoomDeliveries('r1', {
        store: rooms.store, machineId: 'm1', readAgentProfile: async () => null,
        startThread: vi.fn(), sendToThread: vi.fn(), readTurnReply: async (_sessionId, localId) => replies[localId] ?? null, push,
      });
      return { push, posted, seat, daemonRun };
    }

    it('posts one reply, the one after the Steer Now, when it reached the running turn', async () => {
      const { push, posted, seat } = await steered({ [n1]: { finished: false, text: 'Reviso' }, [n2]: { finished: true, text: 'B' } });

      expect(await notifyRoomTurnReady('s1')).toBe(true);

      expect(await posted()).toEqual(['B']);
      expect(push.sendToAllDevicesAsync).toHaveBeenCalledTimes(1);
      expect(await seat()).toMatchObject({ readThroughSeq: 2 });
      expect((await seat()).inFlight).toBeUndefined();
    });

    it('the turn ended before the Steer Now reached the agent: its own reply now, the Steer Now\'s when its turn ends', async () => {
      const replies: Record<string, TurnReply | null> = { [n1]: { finished: true, text: 'A' } };
      const { push, posted, seat } = await steered(replies);

      expect(await notifyRoomTurnReady('s1')).toBe(true);
      expect(await posted()).toEqual(['A']);
      expect(await seat()).toMatchObject({ readThroughSeq: 1, inFlight: { localId: n2 } });

      replies[n2] = { finished: true, text: 'B' };
      expect(await notifyRoomTurnReady('s1')).toBe(true);
      expect(await posted()).toEqual(['A', 'B']);
      expect(await seat()).toMatchObject({ readThroughSeq: 2 });
      expect((await seat()).inFlight).toBeUndefined();
      expect(push.sendToAllDevicesAsync).toHaveBeenCalledTimes(2);
    });

    it('a Steer Now whose own turn has only just begun is not posted early', async () => {
      const replies: Record<string, TurnReply | null> = { [n1]: { finished: true, text: 'A' }, [n2]: { finished: false, text: null } };
      const { posted, seat } = await steered(replies);

      expect(await notifyRoomTurnReady('s1')).toBe(true);
      expect(await posted()).toEqual(['A']);
      expect(await seat()).toMatchObject({ readThroughSeq: 1, inFlight: { localId: n2 } });

      replies[n2] = { finished: true, text: 'B' };
      await notifyRoomTurnReady('s1');
      expect(await posted()).toEqual(['A', 'B']);
      expect((await seat()).inFlight).toBeUndefined();
    });

    describe('when its daemon ended the turn it was sent past before that turn\'s ready', () => {
      it('keeps the Steer Now whose own turn has only just begun, and posts it at its own ready', async () => {
        const replies: Record<string, TurnReply | null> = { [n1]: { finished: false, text: 'Reviso' } };
        const { posted, seat, daemonRun } = await steered(replies);
        replies[n1] = { finished: true, text: 'A' };
        replies[n2] = { finished: false, text: null };
        await daemonRun();
        expect(await posted()).toEqual(['A']);

        // The ready of the turn that ended: the room already told the user about it.
        expect(await notifyRoomTurnReady('s1')).toBe(true);
        expect(await posted()).toEqual(['A']);
        expect(await seat()).toMatchObject({ readThroughSeq: 1, inFlight: { localId: n2 } });

        replies[n2] = { finished: true, text: 'B' };
        expect(await notifyRoomTurnReady('s1')).toBe(true);
        expect(await posted()).toEqual(['A', 'B']);
        expect((await seat()).inFlight).toBeUndefined();
      });

      it('takes over that ready\'s notice while the Steer Now is not in the transcript yet, and ends the Steer Now at its own ready', async () => {
        const replies: Record<string, TurnReply | null> = { [n1]: { finished: true, text: 'A' } };
        const { push, posted, seat, daemonRun } = await steered(replies);
        await daemonRun();
        expect(push.sendToAllDevicesAsync).toHaveBeenCalledTimes(1);

        expect(await notifyRoomTurnReady('s1')).toBe(true);
        expect(await seat()).toMatchObject({ readThroughSeq: 1, inFlight: { localId: n2 } });

        // Its own turn ended without a completion marker: its ready ends it all the same.
        replies[n2] = { finished: false, text: 'B' };
        expect(await notifyRoomTurnReady('s1')).toBe(true);
        expect(await posted()).toEqual(['A', 'B']);
        expect((await seat()).inFlight).toBeUndefined();
        expect(push.sendToAllDevicesAsync).toHaveBeenCalledTimes(2);
      });
    });
  });
});

import { afterEach, describe, expect, it, vi } from 'vitest';

import { AGENT_ROOM_MAX_AGENT_TURNS, accountSettingsParse, agentRoomKvKey, sealAccountScopedBlobCiphertext, type AgentRoomV1 } from '@happier-dev/protocol';

import { createInMemoryAccountKv } from '@/api/kv/inMemoryAccountKv.testkit';
import { resetSessionNotificationMuteForTests, trackSessionNotificationMute } from '@/session/notifications/sessionNotificationMute';
import { resetActiveAccountSettingsSnapshotForTests, setActiveAccountSettingsSnapshot } from '@/settings/accountSettings/activeAccountSettingsSnapshot';

import { AgentRoomStore } from './agentRoomStore';
import { completeRoomTurn } from './completeRoomTurn';

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

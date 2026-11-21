import { EventEmitter } from 'node:events'

import { afterEach, describe, expect, it, vi } from 'vitest'

import { accountSettingsParse, agentRoomKvKey, sealAccountScopedBlobCiphertext, type AgentRoomV1 } from '@happier-dev/protocol'

import { createInMemoryAccountKv } from '@/api/kv/inMemoryAccountKv.testkit'
import { resetAgentRoomsForTests, startAgentRooms } from '@/session/agentRooms/startAgentRooms'
import type { TurnReply } from '@/session/services/readTurnReplyAfterLocalId'

const { notifyParentSessionInBackground } = vi.hoisted(() => ({
  notifyParentSessionInBackground: vi.fn(),
}))

vi.mock('@/session/lineage/notifyParentSession', () => ({
  notifyParentSessionInBackground,
}))

import { sendReadyWithPushNotification } from '@/agent/runtime/sendReadyWithPushNotification'
import { setActiveAccountSettingsSnapshot } from '@/settings/accountSettings/activeAccountSettingsSnapshot'

function createSessionStub(sessionId = 'session-1') {
  return {
    sessionId,
    sendSessionEvent: vi.fn(),
  }
}

describe('sendReadyWithPushNotification', () => {
  afterEach(() => {
    notifyParentSessionInBackground.mockClear()
    setActiveAccountSettingsSnapshot({
      source: 'none',
      settings: accountSettingsParse({}),
      settingsVersion: 0,
      loadedAtMs: 0,
      settingsSecretsReadKeys: [],
    })
    vi.unstubAllGlobals()
  })

  it('emits ready event and sends push notification', () => {
    const sendToAllDevices = vi.fn()
    const session = createSessionStub('session-123')

    sendReadyWithPushNotification({
      session: session as any,
      pushSender: { sendToAllDevices },
      waitingForCommandLabel: 'Qwen Code',
      logPrefix: '[Qwen]',
    })

    expect(session.sendSessionEvent).toHaveBeenCalledWith({ type: 'ready' })
    expect(sendToAllDevices).toHaveBeenCalledWith(
      'Qwen Code',
      'Qwen Code is waiting for your command',
      { sessionId: 'session-123' },
    )
  })

  it('tells the parent session the turn finished, with the same excerpt and turn identity', () => {
    const session = createSessionStub('child-1')

    sendReadyWithPushNotification({
      session: session as any,
      pushSender: { sendToAllDevices: vi.fn() },
      waitingForCommandLabel: 'Codex',
      logPrefix: '[Codex]',
      assistantPreviewText: 'All green.',
      turnKey: 'turn-7',
    })

    expect(notifyParentSessionInBackground).toHaveBeenCalledWith({
      session,
      event: { kind: 'turn_completed', assistantPreviewText: 'All green.', turnKey: 'turn-7' },
    })
  })

  it('still emits ready and the parent notice when no push sender exists', () => {
    const session = createSessionStub('child-2')

    sendReadyWithPushNotification({
      session: session as any,
      pushSender: null,
      waitingForCommandLabel: 'Claude',
      logPrefix: '[Claude]',
    })

    expect(session.sendSessionEvent).toHaveBeenCalledWith({ type: 'ready' })
    expect(notifyParentSessionInBackground).toHaveBeenCalledOnce()
  })

  it('uses the latest assistant preview text when enabled', () => {
    const sendToAllDevices = vi.fn()
    const session = createSessionStub('session-123')

    sendReadyWithPushNotification({
      session: session as any,
      pushSender: { sendToAllDevices },
      waitingForCommandLabel: 'Qwen Code',
      logPrefix: '[Qwen]',
      sessionTitle: 'Review branch',
      assistantPreviewText: 'The branch is ready to review.',
      includeAssistantPreviewText: true,
    })

    expect(sendToAllDevices).toHaveBeenCalledWith(
      'Review branch',
      'The branch is ready to review.',
      { sessionId: 'session-123' },
    )
  })

  it('sends the raw reply as a clean preview with the agent as subtitle and its options', () => {
    const sendToAllDevices = vi.fn()
    const session = {
      ...createSessionStub('session-9'),
      getMetadataSnapshot: () => ({ agentIdentityV1: { v: 1, id: 'agent-1', name: 'Mateo', emoji: '🤖' } }),
    }

    sendReadyWithPushNotification({
      session: session as any,
      pushSender: { sendToAllDevices },
      waitingForCommandLabel: 'Codex',
      logPrefix: '[Codex]',
      sessionTitle: 'Checkout',
      assistantPreviewText: 'Ya está abierto.\n\n**No se realizó ningún cobro.**\n\nMateo 🤖\n<options>\n<option>Comprar</option>\n<option>Cancelar</option>\n</options>',
      includeAssistantPreviewText: true,
    })

    expect(sendToAllDevices).toHaveBeenCalledWith(
      'Checkout',
      'Ya está abierto. No se realizó ningún cobro.',
      { sessionId: 'session-9', subtitle: 'Mateo', options: ['Comprar', 'Cancelar'] },
    )
  })

  it('falls back to waiting text when assistant preview text is disabled', () => {
    const sendToAllDevices = vi.fn()
    const session = createSessionStub('session-123')

    sendReadyWithPushNotification({
      session: session as any,
      pushSender: { sendToAllDevices },
      waitingForCommandLabel: 'Qwen Code',
      logPrefix: '[Qwen]',
      sessionTitle: 'Review branch',
      assistantPreviewText: 'The branch is ready to review.',
      includeAssistantPreviewText: false,
    })

    expect(sendToAllDevices).toHaveBeenCalledWith(
      'Review branch',
      'Qwen Code is waiting for your command',
      { sessionId: 'session-123' },
    )
  })

  it('can suppress push notifications while still emitting ready event', () => {
    const sendToAllDevices = vi.fn()
    const session = createSessionStub('session-999')

    sendReadyWithPushNotification({
      session: session as any,
      pushSender: { sendToAllDevices },
      waitingForCommandLabel: 'Codex',
      logPrefix: '[Codex]',
      shouldSendPush: () => false,
    })

    expect(session.sendSessionEvent).toHaveBeenCalledWith({ type: 'ready' })
    expect(sendToAllDevices).not.toHaveBeenCalled()
  })

  it('redacts non-Axios push errors before logging', () => {
    const session = createSessionStub('session-456')
    const pushError = new Error(
      'push unavailable for https://alice:SUPER_SECRET_PASSWORD@push.example.test/v1/send?token=secret Authorization: Bearer PUSH_SECRET',
    )
    const sendToAllDevices = vi.fn(() => {
      throw pushError
    })
    const loggerDebug = vi.fn()

    sendReadyWithPushNotification({
      session: session as any,
      pushSender: { sendToAllDevices },
      waitingForCommandLabel: 'OpenCode',
      logPrefix: '[OpenCode]',
      loggerDebug,
    })

    expect(session.sendSessionEvent).toHaveBeenCalledWith({ type: 'ready' })
    expect(sendToAllDevices).toHaveBeenCalledTimes(1)
    const [, logged] = loggerDebug.mock.calls[0] ?? []
    expect(logged).toEqual(expect.objectContaining({
      name: 'Error',
      message: 'push unavailable for https://push.example.test/v1/send Authorization: <redacted>',
    }))
    expect(JSON.stringify(logged)).not.toContain('SUPER_SECRET_PASSWORD')
    expect(JSON.stringify(logged)).not.toContain('token=secret')
    expect(JSON.stringify(logged)).not.toContain('PUSH_SECRET')
  })

  it('sanitizes axios-shaped errors before logging', () => {
    const session = createSessionStub('session-789')
    const pushError = {
      isAxiosError: true,
      name: 'AxiosError',
      message: 'Request failed with status code 401',
      config: {
        method: 'get',
        url: 'https://api.example.test/v1/push-tokens?token=secret',
        headers: { Authorization: 'Bearer super-secret' },
      },
      response: { status: 401 },
    }
    const sendToAllDevices = vi.fn(() => {
      throw pushError
    })
    const loggerDebug = vi.fn()

    sendReadyWithPushNotification({
      session: session as any,
      pushSender: { sendToAllDevices },
      waitingForCommandLabel: 'Codex',
      logPrefix: '[Codex]',
      loggerDebug,
    })

    const [, logged] = loggerDebug.mock.calls[0] ?? []
    expect(logged).toEqual(expect.objectContaining({
      name: 'AxiosError',
      status: 401,
      method: 'GET',
      url: 'https://api.example.test/v1/push-tokens',
    }))
    expect(JSON.stringify(logged)).not.toContain('Authorization')
    expect(JSON.stringify(logged)).not.toContain('super-secret')
    expect(JSON.stringify(logged)).not.toContain('token=secret')
  })

  describe('in a room thread', () => {
    const machineKey = new Uint8Array(32).fill(2)
    const credentials = { token: 't', encryption: { type: 'dataKey' as const, publicKey: new Uint8Array(32), machineKey } }
    const env = { HAPPIER_AGENT_IDENTITY_JSON: JSON.stringify({ v: 1, id: 'a-mateo', name: 'Mateo', emoji: '🤖' }) }
    const direct: AgentRoomV1 = {
      v: 1, id: 'direct-a-mateo', kind: 'direct', title: 'Mateo', userName: 'Manny', lastSeq: 0, createdAt: 0, updatedAt: 0,
      members: [{ agentId: 'a-mateo', name: 'Mateo', emoji: '🤖', machineId: 'm1', directory: '/w1' }],
    }
    const localId = 'room.direct-a-mateo.a-mateo.n1'

    afterEach(() => resetAgentRoomsForTests())

    // The seat thread's runner and the ready owner share one push channel, as in `ApiClient`.
    async function startSeatThread(
      readTurnReply: (sessionId: string, localId: string) => Promise<TurnReply | 'thread_gone' | null> = async () => ({ finished: true, text: 'Listo, ya quedó.' }),
    ) {
      const kv = createInMemoryAccountKv()
      await kv.transport.mutate([{ key: agentRoomKvKey(direct.id), version: -1,
        value: sealAccountScopedBlobCiphertext({ kind: 'agent_room', material: { type: 'dataKey', machineKey }, payload: direct, randomBytes: (n) => new Uint8Array(n) }) }])
      const push = { sendToAllDevices: vi.fn(), sendToAllDevicesAsync: vi.fn(async () => {}) }
      const session = Object.assign(new EventEmitter(), { sessionId: 'seat-1', sendSessionEvent: vi.fn() })
      const rooms = startAgentRooms(session, credentials, { transport: kv.transport, env, push, readTurnReply })!
      await rooms.store.appendMessage(direct.id, { author: { kind: 'user' }, text: '¿Cómo vas?', mentions: ['a-mateo'] })
      await rooms.store.startDelivery(direct.id, 'a-mateo', { localId, throughSeq: 1 }, null)
      return { rooms, session, push }
    }

    function ready(session: Awaited<ReturnType<typeof startSeatThread>>['session'], push: Awaited<ReturnType<typeof startSeatThread>>['push']) {
      sendReadyWithPushNotification({
        session: session as any,
        pushSender: push,
        waitingForCommandLabel: 'Codex',
        logPrefix: '[Codex]',
        assistantPreviewText: 'Listo, ya quedó.',
      })
    }

    it('sends no ready push for a turn that answers a room delivery: the room notice is its only push', async () => {
      const { rooms, session, push } = await startSeatThread()

      session.emit('provider-input-delivered', { localId })
      ready(session, push)

      expect(session.sendSessionEvent).toHaveBeenCalledWith({ type: 'ready' })
      await vi.waitFor(async () => {
        expect((await rooms.store.getRoom(direct.id))!.room.lastSeq).toBe(2)
        expect(push.sendToAllDevicesAsync).toHaveBeenCalledWith('Mateo 🤖', 'Listo, ya quedó.', { type: 'room_mention', roomId: direct.id, seq: 2 })
      })
      expect(push.sendToAllDevicesAsync).toHaveBeenCalledTimes(1)
      expect(push.sendToAllDevices).not.toHaveBeenCalled()
    })

    it('still sends that turn\'s ready to webhook channels, which get no room push', async () => {
      const fetchSpy = vi.fn(async () => ({ ok: true, status: 202 }))
      vi.stubGlobal('fetch', fetchSpy)
      setActiveAccountSettingsSnapshot({
        source: 'network',
        settings: accountSettingsParse({ notificationChannelsV1: [
          { v: 1, id: 'builtin:expo_push', kind: 'expo_push', enabled: true },
          { v: 1, id: 'webhook-primary', kind: 'webhook', enabled: true, url: 'https://hooks.example.test/happier' },
        ] }),
        settingsVersion: 1, loadedAtMs: 0, settingsSecretsReadKeys: [],
      })
      const { session, push } = await startSeatThread()

      session.emit('provider-input-delivered', { localId })
      ready(session, push)

      await vi.waitFor(() => expect(fetchSpy).toHaveBeenCalledTimes(1))
      expect(fetchSpy.mock.calls.at(0)?.at(0)).toBe('https://hooks.example.test/happier')
      // The phone gets the room push only.
      expect(push.sendToAllDevicesAsync).toHaveBeenCalledTimes(1)
      expect(push.sendToAllDevicesAsync).toHaveBeenCalledWith('Mateo 🤖', 'Listo, ya quedó.', { type: 'room_mention', roomId: direct.id, seq: 2 })
      expect(push.sendToAllDevices).not.toHaveBeenCalled()
    })

    it('still sends the ready push for a later turn the user started in that thread', async () => {
      const { session, push } = await startSeatThread()
      session.emit('provider-input-delivered', { localId })
      ready(session, push)
      await vi.waitFor(() => expect(push.sendToAllDevicesAsync).toHaveBeenCalledTimes(1))

      session.emit('provider-input-delivered', { localId: 'typed-in-the-thread' })
      ready(session, push)

      expect(push.sendToAllDevices).toHaveBeenCalledTimes(1)
      expect(push.sendToAllDevices).toHaveBeenCalledWith('Codex', 'Listo, ya quedó.', { sessionId: 'seat-1' })
    })

    it('still sends the ready push for a later turn when the room delivery\'s own turn ended without a ready', async () => {
      const { rooms, session, push } = await startSeatThread()
      // The room turn ends by draining what the user typed meanwhile, so only that turn's ready comes.
      session.emit('provider-input-delivered', { localId })
      session.emit('provider-input-delivered', { localId: 'typed-in-the-thread' })
      ready(session, push)

      expect(push.sendToAllDevices).toHaveBeenCalledWith('Codex', 'Listo, ya quedó.', { sessionId: 'seat-1' })
      // The room delivery is still answered.
      await vi.waitFor(async () => expect((await rooms.store.getRoom(direct.id))!.room.lastSeq).toBe(2))
    })

    it('still sends the ready push when the room reply could not be posted', async () => {
      const { rooms, session, push } = await startSeatThread(async () => null)

      session.emit('provider-input-delivered', { localId })
      ready(session, push)

      await vi.waitFor(() => expect(push.sendToAllDevices).toHaveBeenCalledWith('Codex', 'Listo, ya quedó.', { sessionId: 'seat-1' }))
      expect(push.sendToAllDevices).toHaveBeenCalledTimes(1)
      expect((await rooms.store.getRoom(direct.id))!.room.lastSeq).toBe(1)
      expect(push.sendToAllDevicesAsync).not.toHaveBeenCalled()
    })
  })

  it('prefers the latest active account settings snapshot over stale ready gating inputs', async () => {
    const fetchSpy = vi.fn(async () => ({
      ok: true,
      status: 202,
    }))
    vi.stubGlobal('fetch', fetchSpy)
    const session = createSessionStub('session-321')

    setActiveAccountSettingsSnapshot({
      source: 'network',
      settings: accountSettingsParse({
        notificationChannelsV1: [
          {
            v: 1,
            id: 'webhook-primary',
            kind: 'webhook',
            enabled: true,
            url: 'https://hooks.example.test/happier',
            topics: {
              ready: true,
              permissionRequest: false,
              userActionRequest: false,
            },
            readyIncludeMessageText: false,
          },
        ],
      }),
      settingsVersion: 7,
      loadedAtMs: 123,
      settingsSecretsReadKeys: [],
    })

    sendReadyWithPushNotification({
      session: session as any,
      pushSender: { sendToAllDevicesAsync: vi.fn(async () => {}) },
      waitingForCommandLabel: 'Codex',
      logPrefix: '[Codex]',
      accountSettings: accountSettingsParse({
        notificationsSettingsV1: {
          v: 1,
          pushEnabled: false,
          ready: false,
          readyIncludeMessageText: false,
          permissionRequest: false,
          userActionRequest: false,
          foregroundBehavior: 'full',
        },
      }),
      sessionTitle: 'Review branch',
      assistantPreviewText: 'Done.',
      shouldSendPush: () => false,
    })

    await vi.waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledTimes(1)
    })

    const url = fetchSpy.mock.calls.at(0)?.at(0)
    const init = fetchSpy.mock.calls.at(0)?.at(1)
    expect(url).toBe('https://hooks.example.test/happier')
    expect(init).toMatchObject({
      method: 'POST',
      headers: {
        'content-type': 'application/json',
      },
    })

  })
})

import { afterEach, describe, expect, it, vi } from 'vitest'

import { accountSettingsParse } from '@happier-dev/protocol'

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

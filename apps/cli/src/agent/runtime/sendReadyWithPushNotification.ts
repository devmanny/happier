import { isSessionNotificationMuted } from '@/session/notifications/sessionNotificationMute'
import { logger } from '@/ui/logger'
import type { SessionClientPort } from '@/api/session/sessionClientPort'
import { serializeAxiosErrorForLog } from '@/api/client/serializeAxiosErrorForLog'
import { AGENT_IDENTITY_METADATA_KEY, parseAgentIdentityV1, type AccountSettings } from '@happier-dev/protocol'
import { buildActivityNotificationContent } from '@/activity/notifications/buildActivityNotificationContent'
import { dispatchActivityNotificationAsync } from '@/activity/notifications/dispatchActivityNotification'
import { getActiveAccountSettingsSnapshot } from '@/settings/accountSettings/activeAccountSettingsSnapshot'
import { notifyParentSessionInBackground } from '@/session/lineage/notifyParentSession'

import type { ExpoPushActivityNotificationOptions } from '@/activity/notifications/sendExpoPushActivityNotification'

type PushSender = {
  sendToAllDevices?: (title: string, body: string, data: Record<string, unknown>, delivery?: ExpoPushActivityNotificationOptions) => void
  sendToAllDevicesAsync?: (title: string, body: string, data: Record<string, unknown>, delivery?: ExpoPushActivityNotificationOptions) => Promise<void>
}

type ReadySession = Pick<SessionClientPort, 'sessionId' | 'sendSessionEvent'> & {
  getMetadataSnapshot?: (() => unknown) | null
}

function resolveReadyNotificationSettingsContext(opts: Readonly<{
  accountSettings?: AccountSettings | null
  settingsSecretsReadKeys?: ReadonlyArray<Uint8Array | null | undefined>
}>): Readonly<{
  settings: AccountSettings | null
  settingsSecretsReadKeys: ReadonlyArray<Uint8Array | null | undefined>
}> {
  const activeSnapshot = getActiveAccountSettingsSnapshot()
  if (activeSnapshot && activeSnapshot.source !== 'none') {
    return {
      settings: activeSnapshot.settings,
      settingsSecretsReadKeys: activeSnapshot.settingsSecretsReadKeys,
    }
  }
  return {
    settings: opts.accountSettings ?? null,
    settingsSecretsReadKeys: opts.settingsSecretsReadKeys ?? [],
  }
}

function readSessionAgentName(session: ReadySession): string | null {
  const metadata = session.getMetadataSnapshot?.()
  if (!metadata || typeof metadata !== 'object') return null
  return parseAgentIdentityV1((metadata as Record<string, unknown>)[AGENT_IDENTITY_METADATA_KEY])?.name ?? null
}

export function sendReadyWithPushNotification(opts: {
  session: ReadySession
  pushSender: PushSender | null
  waitingForCommandLabel: string
  logPrefix: string
  sessionTitle?: string | null
  assistantPreviewText?: string | null
  includeAssistantPreviewText?: boolean
  accountSettings?: AccountSettings | null
  settingsSecretsReadKeys?: ReadonlyArray<Uint8Array | null | undefined>
  loggerDebug?: (message: string, error: unknown) => void
  shouldSendPush?: () => boolean
  /** Provider turn identity (when known) so a re-emitted ready for the same turn is not a new parent notice. */
  turnKey?: string | null
}): void {
  opts.session.sendSessionEvent({ type: 'ready' })

  // A session spawned by another session reports its completed turn to that parent
  // regardless of the user's push settings: the parent is an agent, not a device.
  notifyParentSessionInBackground({
    session: opts.session,
    event: {
      kind: 'turn_completed',
      assistantPreviewText: opts.assistantPreviewText ?? null,
      turnKey: opts.turnKey ?? null,
    },
  })

  if (!opts.pushSender) return

  try {
    const agentName = readSessionAgentName(opts.session)
    const currentSettingsContext = resolveReadyNotificationSettingsContext({
      accountSettings: opts.accountSettings,
      settingsSecretsReadKeys: opts.settingsSecretsReadKeys,
    })
    if (currentSettingsContext.settings) {
      const loggerDebug = opts.loggerDebug ?? logger.debug.bind(logger)
      const expoPushSender = opts.pushSender?.sendToAllDevicesAsync
        ? {
          sendToAllDevicesAsync: opts.pushSender.sendToAllDevicesAsync.bind(opts.pushSender),
        }
        : opts.pushSender?.sendToAllDevices
          ? {
            sendToAllDevicesAsync: async (title: string, body: string, data: Record<string, unknown>, delivery?: ExpoPushActivityNotificationOptions) => {
              const sessionId = typeof data.sessionId === 'string' ? data.sessionId : opts.session.sessionId
              opts.pushSender?.sendToAllDevices?.(title, body, { ...data, sessionId }, delivery)
            },
          }
          : null
      void dispatchActivityNotificationAsync({
        settings: currentSettingsContext.settings,
        settingsSecretsReadKeys: currentSettingsContext.settingsSecretsReadKeys,
        expoPushSender,
        event: {
          topic: 'ready',
          sessionId: opts.session.sessionId,
          sessionTitle: opts.sessionTitle,
          waitingForCommandLabel: opts.waitingForCommandLabel,
          assistantPreviewText: opts.assistantPreviewText,
          agentName,
        },
      }).catch((pushError) => {
        loggerDebug(`${opts.logPrefix} Failed to send ready push`, serializeAxiosErrorForLog(pushError))
      })
      return
    }
    const shouldSend = opts.shouldSendPush ?? (() => true)
    if (shouldSend() !== true) return
    if (isSessionNotificationMuted(opts.session.sessionId)) return
    if (!opts.pushSender?.sendToAllDevices) return
    const content = buildActivityNotificationContent({
      topic: 'ready',
      sessionId: opts.session.sessionId,
      sessionTitle: opts.sessionTitle,
      waitingForCommandLabel: opts.waitingForCommandLabel,
      assistantPreviewText: opts.assistantPreviewText,
      agentName,
    }, { readyIncludeMessageText: opts.includeAssistantPreviewText !== false })
    opts.pushSender.sendToAllDevices(content.title, content.body, content.data)
  } catch (pushError) {
    const loggerDebug = opts.loggerDebug ?? logger.debug.bind(logger)
    loggerDebug(`${opts.logPrefix} Failed to send ready push`, serializeAxiosErrorForLog(pushError))
  }
}

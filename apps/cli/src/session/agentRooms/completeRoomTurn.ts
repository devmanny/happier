import {
  AGENT_ROOM_MAX_AGENT_TURNS,
  buildAssistantMessagePreview,
  roomAgentStreak,
  roomMessageAuthorLabel,
  roomReplyNotices,
  roomUserLabel,
  resolveNotificationChannelsV1FromAccountSettings,
  type AgentRoomAuthor,
  type ExpoPushNotificationChannelV1,
} from '@happier-dev/protocol';

import type { ExpoPushActivityNotificationOptions } from '@/activity/notifications/sendExpoPushActivityNotification';
import { isSessionNotificationMuted } from '@/session/notifications/sessionNotificationMute';
import { getActiveAccountSettingsSnapshot } from '@/settings/accountSettings/activeAccountSettingsSnapshot';
import { logger } from '@/ui/logger';

import type { AgentRoomStore } from './agentRoomStore';

/** The push channel tasks and the daemon already use (`PushNotificationClient`). */
export type RoomPushSender = Readonly<{
  sendToAllDevicesAsync: (title: string, body: string, data?: Record<string, unknown>, options?: ExpoPushActivityNotificationOptions) => Promise<void>;
}>;

const NOTICE_EXCERPT_CHARS = 160;
const HIDDEN_TEXT_BODY = 'New message';

/**
 * Ends a member's room turn: posts its reply, moves its marker and clears the delivery (once, see
 * `AgentRoomStore.finishTurn`), then tells the user what `roomReplyNotices` says: every reply once
 * (a mention when it mentions them outside an agent's own chat) and a hand-off that hit the brake.
 * Every room notice carries `{type: 'room_mention', roomId, seq}` (the brake: `room_brake`), so a tap
 * opens the room at that message. The runner calls it when the turn is ready; the daemon calls it
 * for a turn whose runner ended without doing so.
 *
 * `'no_reply'` when the turn ended without a final text, so nothing was posted (or its room is gone).
 *
 * Room notices go on the account's push channel (`expo_push`, as the turn-finished push does). A
 * reply's own notice stands for its thread's turn-finished push, which `sendReadyWithPushNotification`
 * doesn't send for a room turn, so it follows that push's settings: no reply text when the user hides
 * it, quiet while a computer is in use, none while the thread's bell is off, and a plain reply only
 * with finished notifications on. The brake is the room's, not the thread's.
 */
export async function completeRoomTurn(params: Readonly<{
  store: AgentRoomStore;
  delivery: Readonly<{ roomId: string; agentId: string; localId: string }>;
  author: Extract<AgentRoomAuthor, { kind: 'agent' }>;
  reply: Readonly<{ finished: boolean; text: string | null }>;
  push: RoomPushSender | null;
}>): Promise<'finished' | 'no_reply' | 'not_in_flight' | 'running'> {
  if (!params.reply.finished) return 'running';
  const { roomId } = params.delivery;
  const result = await params.store.finishTurn({ ...params.delivery, author: params.author, text: params.reply.text });
  if (!result.finished) return 'not_in_flight';
  const message = result.message;
  if (!message) return 'no_reply';
  const settings = getActiveAccountSettingsSnapshot()?.settings ?? null;
  const channel = resolveNotificationChannelsV1FromAccountSettings(settings)
    .find((entry): entry is ExpoPushNotificationChannelV1 => entry.kind === 'expo_push' && entry.enabled === true);
  if (!params.push || !channel) return 'finished';

  const room = (await params.store.getRoom(roomId))?.room;
  if (!room) return 'finished';
  const window = await params.store.readMessages(roomId, { fromSeq: message.seq - AGENT_ROOM_MAX_AGENT_TURNS + 1, toSeq: message.seq });
  const threadMuted = isSessionNotificationMuted(params.author.sessionId);
  const notices = roomReplyNotices({ room, message, agentStreak: roomAgentStreak(window, message.seq) })
    .filter((notice) => notice === 'brake' || (!threadMuted && (notice !== 'reply' || channel.topics.ready === true)));
  if (notices.length === 0) return 'finished';
  const from = roomMessageAuthorLabel(message.author, roomUserLabel(room));
  const agentName = message.author.kind === 'agent' ? message.author.name ?? null : null;
  // Without its session cards and options; a reply of nothing else still says it came.
  const excerpt = channel.readyIncludeMessageText === false
    ? HIDDEN_TEXT_BODY
    : buildAssistantMessagePreview(message.text, { agentName, maxChars: NOTICE_EXCERPT_CHARS }).text || HIDDEN_TEXT_BODY;
  const quiet = settings?.notificationsSettingsV1?.mutePhoneWhenComputerFocused === true;
  const push = params.push;
  const send = (title: string, body: string, data: Record<string, unknown>) => (quiet
    ? push.sendToAllDevicesAsync(title, body, data, { suppressIfComputerFocused: true })
    : push.sendToAllDevicesAsync(title, body, data));
  for (const notice of notices) {
    try {
      if (notice === 'reply') {
        await send(from, room.kind === 'direct' ? excerpt : `${room.title}: ${excerpt}`, { type: 'room_mention', roomId, seq: message.seq });
      } else if (notice === 'mention') {
        await send(`${from} mentioned you`, `${room.title}: ${excerpt}`, { type: 'room_mention', roomId, seq: message.seq });
      } else {
        await send(
          'Room on hold',
          `${room.title}: ${AGENT_ROOM_MAX_AGENT_TURNS} agent turns in a row. Write to let them continue.`,
          { type: 'room_brake', roomId, seq: message.seq },
        );
      }
    } catch (error) {
      logger.warn('[ROOMS] Could not push a room notice', { roomId, notice, error: error instanceof Error ? error.message : String(error) });
    }
  }
  return 'finished';
}

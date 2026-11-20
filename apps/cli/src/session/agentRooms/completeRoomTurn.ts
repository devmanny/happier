import {
  AGENT_ROOM_MAX_AGENT_TURNS,
  roomAgentStreak,
  roomMessageAuthorLabel,
  roomReplyNotices,
  roomUserLabel,
  type AgentRoomAuthor,
} from '@happier-dev/protocol';

import { logger } from '@/ui/logger';

import type { AgentRoomStore } from './agentRoomStore';

/** The push channel tasks and the daemon already use (`PushNotificationClient`). */
export type RoomPushSender = Readonly<{
  sendToAllDevicesAsync: (title: string, body: string, data?: Record<string, unknown>) => Promise<void>;
}>;

const NOTICE_EXCERPT_CHARS = 160;

function excerpt(text: string): string {
  const line = text.replace(/\s+/g, ' ').trim();
  return line.length <= NOTICE_EXCERPT_CHARS ? line : `${line.slice(0, NOTICE_EXCERPT_CHARS - 1)}…`;
}

/**
 * Ends a member's room turn: posts its reply, moves its marker and clears the delivery (once, see
 * `AgentRoomStore.finishTurn`), then tells the user when the reply mentions them or when its
 * hand-off hit the brake. The runner calls it when the turn is ready; the daemon calls it for a turn
 * whose runner ended without doing so.
 */
export async function completeRoomTurn(params: Readonly<{
  store: AgentRoomStore;
  delivery: Readonly<{ roomId: string; agentId: string; localId: string }>;
  author: Extract<AgentRoomAuthor, { kind: 'agent' }>;
  reply: Readonly<{ finished: boolean; text: string | null }>;
  push: RoomPushSender | null;
  pushEnabled: () => boolean;
}>): Promise<'finished' | 'not_in_flight' | 'running'> {
  if (!params.reply.finished) return 'running';
  const { roomId } = params.delivery;
  const result = await params.store.finishTurn({ ...params.delivery, author: params.author, text: params.reply.text });
  if (!result.finished) return 'not_in_flight';
  const message = result.message;
  if (!message || !params.push || !params.pushEnabled()) return 'finished';

  const window = await params.store.readMessages(roomId, { fromSeq: message.seq - AGENT_ROOM_MAX_AGENT_TURNS + 1, toSeq: message.seq });
  const notices = roomReplyNotices({ message, agentStreak: roomAgentStreak(window, message.seq) });
  if (notices.length === 0) return 'finished';
  const room = (await params.store.getRoom(roomId))?.room;
  const title = room?.title ?? 'Room';
  const from = roomMessageAuthorLabel(message.author, room ? roomUserLabel(room) : 'User');
  for (const notice of notices) {
    try {
      if (notice === 'mention') {
        await params.push.sendToAllDevicesAsync(`${from} mentioned you`, `${title}: ${excerpt(message.text)}`, { type: 'room_mention', roomId, seq: message.seq });
      } else {
        await params.push.sendToAllDevicesAsync(
          'Room on hold',
          `${title}: ${AGENT_ROOM_MAX_AGENT_TURNS} agent turns in a row. Write to let them continue.`,
          { type: 'room_brake', roomId, seq: message.seq },
        );
      }
    } catch (error) {
      logger.warn('[ROOMS] Could not push a room notice', { roomId, notice, error: error instanceof Error ? error.message : String(error) });
    }
  }
  return 'finished';
}

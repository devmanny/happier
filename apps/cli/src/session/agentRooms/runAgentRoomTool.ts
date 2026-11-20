import { roomMessageAuthorLabel, type AgentIdentityV1 } from '@happier-dev/protocol';

import { ACCOUNT_KV_BULK_GET_MAX_KEYS } from '@/api/kv/accountKvHttpTransport';

import type { AgentRoomStore } from './agentRoomStore';

export type AgentRoomCaller = Readonly<{
  agent: Pick<AgentIdentityV1, 'id' | 'name' | 'emoji'> | null;
  sessionId: string;
}>;

/** How the tools name the user in a room's messages (as the task tools do: assignee "user"). */
export const ROOM_TOOL_USER_LABEL = 'user';

/** One `sala_leer` call returns at most one bulk read of messages, the newest of the range. */
const ROOM_READ_PAGE_MESSAGES = ACCOUNT_KV_BULK_GET_MAX_KEYS;

function readSeq(input: Record<string, unknown>, key: 'fromSeq' | 'toSeq'): number | undefined {
  const value = input[key];
  return typeof value === 'number' && Number.isSafeInteger(value) && value > 0 ? value : undefined;
}

/** `sala_leer`, run in the calling session's runner: a member reads its room's messages. */
export async function runAgentRoomTool(params: Readonly<{
  store: AgentRoomStore;
  caller: AgentRoomCaller;
  operation: 'read';
  input: Record<string, unknown>;
}>): Promise<Record<string, unknown>> {
  const { store, caller, input } = params;
  const roomId = typeof input.roomId === 'string' ? input.roomId.trim() : '';
  if (!roomId) return { ok: false, error: 'roomId is required' };
  const current = await store.getRoom(roomId);
  if (!current) return { ok: false, error: `room ${roomId} not found` };
  const { room } = current;
  if (!caller.agent || !room.members.some((member) => member.agentId === caller.agent!.id)) {
    return { ok: false, error: `You are not a member of room ${roomId}.` };
  }

  const toSeq = Math.min(readSeq(input, 'toSeq') ?? room.lastSeq, room.lastSeq);
  const fromSeq = Math.max(readSeq(input, 'fromSeq') ?? 1, toSeq - ROOM_READ_PAGE_MESSAGES + 1, 1);
  const messages = toSeq >= fromSeq ? await store.readMessages(roomId, { fromSeq, toSeq }) : [];
  return {
    ok: true,
    roomId,
    title: room.title,
    members: room.members.map((member) => ({ agentId: member.agentId, name: member.name ?? member.agentId })),
    lastSeq: room.lastSeq,
    fromSeq,
    toSeq,
    messages: messages.map((message) => ({
      seq: message.seq,
      at: new Date(message.at).toISOString(),
      from: roomMessageAuthorLabel(message.author, ROOM_TOOL_USER_LABEL),
      text: message.text,
    })),
    ...(fromSeq > 1 ? { earlier: { toSeq: fromSeq - 1 } } : {}),
  };
}

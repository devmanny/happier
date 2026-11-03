import { z } from 'zod';
import type { StopReason } from '@agentclientprotocol/sdk';
import type { AcpExtensionHandlers } from '@/agent/acp/AcpBackend';
import { defineAcpExtensionNotification } from '@/agent/acp/connection/types';
import { readPromptStopReason } from '@/agent/acp/backend/turn/acpTurnCompletion';

export const KIMI_AUTONOMOUS_TURNS_CAPABILITY = 'kimi/autonomous-turns';
export const KIMI_AUTONOMOUS_TURN_METHOD = '_kimi/autonomous_turn';

const identity = { sessionId: z.string().min(1), turnId: z.number().int().nonnegative() };
const params = z.discriminatedUnion('event', [
  z.object({ ...identity, event: z.literal('started') }),
  z.object({ ...identity, event: z.literal('update'), update: z.record(z.string(), z.unknown()) }),
  z.object({ ...identity, event: z.literal('ended'),
    stopReason: z.custom<StopReason>(value => readPromptStopReason({ stopReason: value }) !== null),
    error: z.string().optional(),
  }),
]);

export function buildKimiAutonomousTurnHandlers(): AcpExtensionHandlers {
  return [defineAcpExtensionNotification({
    method: KIMI_AUTONOMOUS_TURN_METHOD,
    params,
    handler: async (event, context) => {
      if (context.agentCapabilitiesMeta?.[KIMI_AUTONOMOUS_TURNS_CAPABILITY] !== true) return;
      await context.providerInitiatedTurn?.apply({ ...event, turnId: String(event.turnId) });
    },
  })];
}

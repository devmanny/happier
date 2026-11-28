import { z } from 'zod';

import { NonBlankOpaqueIdentifierSchema } from '../strings/opaqueIdentifier.js';

/** Origin of an explicit inter-session user message, stored in meta.happier as session_message.v1. */
export const SessionMessageV1Schema = z.object({
  senderSessionId: NonBlankOpaqueIdentifierSchema,
  targetSessionId: NonBlankOpaqueIdentifierSchema,
}).passthrough();
export type SessionMessageV1 = z.infer<typeof SessionMessageV1Schema>;

export function parseSessionMessageV1(input: unknown): SessionMessageV1 | null {
  const parsed = SessionMessageV1Schema.safeParse(input);
  return parsed.success ? parsed.data : null;
}

import { z } from 'zod';

/**
 * An agent's profile photo at `agentphoto/<id>` (kind `agent_photo`): a small square JPEG, base64,
 * sealed for the account's devices like its profile. Kept apart from the profile so listing the
 * profiles (and reading one at spawn) stays light, and the photo loads only where it is drawn.
 */
export const AGENT_PHOTO_KV_PREFIX = 'agentphoto/';

export function agentPhotoKvKey(agentId: string): string {
  return `${AGENT_PHOTO_KV_PREFIX}${agentId}`;
}

export const AgentPhotoV1Schema = z.object({
  v: z.literal(1),
  id: z.string().min(1),
  mime: z.literal('image/jpeg'),
  data: z.string().min(1),
  updatedAt: z.number(),
}).passthrough();
export type AgentPhotoV1 = z.infer<typeof AgentPhotoV1Schema>;

export function parseAgentPhotoV1(value: unknown): AgentPhotoV1 | null {
  const parsed = AgentPhotoV1Schema.safeParse(value);
  return parsed.success ? parsed.data : null;
}

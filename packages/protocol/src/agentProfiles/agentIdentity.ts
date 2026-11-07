import { z } from 'zod';

/**
 * A user-defined agent (name, emoji, description) a session works as. The full profile lives
 * sealed in the account's UserKVStore under `agent/<id>/profile`; a spawn carries only this
 * identity, which the runner keeps in `metadata.agentIdentityV1` and gives to the model.
 */
export const AgentIdentityV1Schema = z.object({
  v: z.literal(1),
  id: z.string().trim().min(1),
  name: z.string().trim().min(1),
  emoji: z.string().trim().min(1).optional(),
  description: z.string().optional(),
}).strip();
export type AgentIdentityV1 = z.infer<typeof AgentIdentityV1Schema>;

/** Spawn → runner hand-off. Kept (not consumed) so a respawned runner still knows who it is. */
export const AGENT_IDENTITY_ENV_KEY = 'HAPPIER_AGENT_IDENTITY_JSON';

/** Session metadata key the runner writes and clients read to show the agent. */
export const AGENT_IDENTITY_METADATA_KEY = 'agentIdentityV1';

/** UserKVStore keys stay opaque: names and titles only live inside the sealed value. */
export function agentProfileKvKey(agentId: string): string {
  return `agent/${agentId}/profile`;
}

export const AGENT_PROFILE_KV_PREFIX = 'agent/';

/** The identity from an object or its JSON text; null when it isn't a usable identity. */
export function parseAgentIdentityV1(value: unknown): AgentIdentityV1 | null {
  let candidate = value;
  if (typeof value === 'string') {
    try {
      candidate = JSON.parse(value);
    } catch {
      return null;
    }
  }
  const parsed = AgentIdentityV1Schema.safeParse(candidate);
  if (!parsed.success) return null;
  const description = parsed.data.description?.trim();
  return {
    v: 1,
    id: parsed.data.id,
    name: parsed.data.name,
    ...(parsed.data.emoji ? { emoji: parsed.data.emoji } : {}),
    ...(description ? { description } : {}),
  };
}

export function buildAgentIdentityPromptTextV1(identity: AgentIdentityV1): string {
  const label = identity.emoji ? `${identity.name} ${identity.emoji}` : identity.name;
  const lines = [
    '## Agent identity',
    `In this session you are the agent "${label}". The user may run several sessions as this same agent at once; each one is a thread of ${identity.name}.`,
    `When you introduce yourself or sign a message as yourself, use the name ${label}.`,
  ];
  if (identity.description) {
    lines.push('', 'Who you are and how you work, as the user wrote it:', identity.description);
  }
  return lines.join('\n');
}

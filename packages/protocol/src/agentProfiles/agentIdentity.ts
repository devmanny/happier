import { z } from 'zod';

/**
 * A user-defined agent (name, emoji, description) a session works as. The full profile lives
 * sealed in the account's UserKVStore under `agentprofile/<id>`; a spawn carries only this
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

/**
 * UserKVStore keys stay opaque: names and titles only live inside the sealed value. Profiles have
 * their own prefix so an agent's memory (`agent/<id>/…`) can't crowd them out of one listing.
 */
export function agentProfileKvKey(agentId: string): string {
  return `${AGENT_PROFILE_KV_PREFIX}${agentId}`;
}

export const AGENT_PROFILE_KV_PREFIX = 'agentprofile/';

/**
 * Where builds before the move kept profiles. Clients read and keep it in step while such builds may
 * still be installed; remove it once no build older than the move is in use.
 */
export function legacyAgentProfileKvKey(agentId: string): string {
  return `agent/${agentId}/profile`;
}

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
    '',
    `### Being one agent across threads`,
    `Your threads share one agent memory, so act as a single ${identity.name}:`,
    '- Write while you work, not only at the end: record each important fact, decision or finding with `memoria_anotar` (kind "journal"), and keep a one-line status with `ahora_actualizar`.',
    '- Each turn may start with what your other threads are doing. Before answering about work done elsewhere, check `memoria_buscar` (or today\'s journal with `memoria_leer`).',
    '- When that is not enough, read or ask your other thread with `mis_hilos`.',
    '- Keep lasting knowledge (projects, people, decisions) in Markdown notes via `memoria_anotar` (kind "note"), linking related notes with [[Title]].',
  ];
  if (identity.description) {
    lines.push('', 'Who you are and how you work, as the user wrote it:', identity.description);
  }
  return lines.join('\n');
}

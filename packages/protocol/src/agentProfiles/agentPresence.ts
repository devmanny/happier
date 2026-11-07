import { z } from 'zod';

/**
 * "Who is where": one record per running thread (session), sealed in the account's UserKVStore
 * under `presence/<sessionId>`. Only that thread writes it. Records are advisory — nothing is
 * locked — and a thread that stops signalling simply ages out, so a crashed runner holds nothing.
 */
export const AGENT_PRESENCE_KV_PREFIX = 'presence/';

/** A thread refreshes its record this often while a turn is running. */
export const AGENT_PRESENCE_HEARTBEAT_MS = 60_000;
/** Readers ignore a record that missed this many heartbeats ("deja de dar señales unos minutos"). */
export const AGENT_PRESENCE_STALE_AFTER_MS = 3 * AGENT_PRESENCE_HEARTBEAT_MS;

export function agentPresenceKvKey(sessionId: string): string {
  return `${AGENT_PRESENCE_KV_PREFIX}${sessionId}`;
}

const HeldItemSchema = z.object({ since: z.number() });

export const AgentPresenceV1Schema = z.object({
  v: z.literal(1),
  sessionId: z.string().min(1),
  agent: z.object({ id: z.string(), name: z.string(), emoji: z.string().optional() }).strip().nullable(),
  providerId: z.string().nullable(),
  machineId: z.string().nullable(),
  host: z.string().nullable(),
  directory: z.string().nullable(),
  task: z.string().nullable(),
  files: z.array(HeldItemSchema.extend({ path: z.string() }).strip()),
  resources: z.array(HeldItemSchema.extend({ name: z.string() }).strip()),
  updatedAt: z.number(),
}).strip();
export type AgentPresenceV1 = z.infer<typeof AgentPresenceV1Schema>;

export function parseAgentPresenceV1(value: unknown): AgentPresenceV1 | null {
  const parsed = AgentPresenceV1Schema.safeParse(value);
  return parsed.success ? parsed.data : null;
}

export function isAgentPresenceLive(record: AgentPresenceV1, now: number): boolean {
  return now - record.updatedAt <= AGENT_PRESENCE_STALE_AFTER_MS;
}

export type PresenceConflict = Readonly<{
  kind: 'file' | 'resource';
  /** The file path or resource name the other thread holds. */
  item: string;
  since: number;
  holder: AgentPresenceV1;
}>;

/** Live threads other than `selfSessionId` that hold `filePath` or `resource`. */
export function findPresenceConflicts(params: Readonly<{
  selfSessionId: string;
  records: readonly AgentPresenceV1[];
  now: number;
  filePath?: string;
  resource?: string;
}>): PresenceConflict[] {
  const conflicts: PresenceConflict[] = [];
  for (const record of params.records) {
    if (record.sessionId === params.selfSessionId || !isAgentPresenceLive(record, params.now)) continue;
    if (params.filePath) {
      const file = record.files.find((entry) => entry.path === params.filePath);
      if (file) conflicts.push({ kind: 'file', item: file.path, since: file.since, holder: record });
    }
    if (params.resource) {
      const resource = record.resources.find((entry) => entry.name === params.resource);
      if (resource) conflicts.push({ kind: 'resource', item: resource.name, since: resource.since, holder: record });
    }
  }
  return conflicts;
}

export function describePresenceHolder(record: AgentPresenceV1): string {
  const who = record.agent ? `${record.agent.name}${record.agent.emoji ? ` ${record.agent.emoji}` : ''}` : 'Another session';
  const task = record.task ? ` (task: ${record.task})` : '';
  return `${who}${task}, session ${record.sessionId}`;
}

function describeAge(ms: number): string {
  const minutes = Math.floor(Math.max(0, ms) / 60_000);
  if (minutes < 1) return 'less than a minute';
  return minutes === 1 ? '1 min' : `${minutes} min`;
}

/** One line for the model, e.g. "Mateo 🤖 (task: Login) … is editing Composer.swift for 4 min". */
export function describePresenceConflict(conflict: PresenceConflict, now: number): string {
  const verb = conflict.kind === 'file' ? 'is editing' : 'is using';
  return `${describePresenceHolder(conflict.holder)} ${verb} ${conflict.item} for ${describeAge(now - conflict.since)}.`;
}

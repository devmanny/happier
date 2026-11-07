import { z } from 'zod';

export const ChangeKindSchema = z.enum([
  'account',
  'automation',
  'artifact',
  'feed',
  'friends',
  'friend_request',
  'friend_accepted',
  'kv',
  'machine',
  'pet',
  'session',
  'share',
]);

export type ChangeKind = z.infer<typeof ChangeKindSchema>;

export const ChangeEntrySchema = z.object({
  cursor: z.number().int().min(0),
  kind: z.string().trim().min(1),
  entityId: z.string(),
  changedAt: z.number().int().min(0),
  hint: z.unknown().nullable().optional(),
}).strict();

export type ChangeEntry = z.infer<typeof ChangeEntrySchema>;

export const ChangesResponseSchema = z.object({
  changes: z.array(ChangeEntrySchema),
  nextCursor: z.number().int().min(0),
}).strict();

export type ChangesResponse = z.infer<typeof ChangesResponseSchema>;

export const CurrentCursorResponseSchema = z.object({
  cursor: z.number().int().min(0),
  changesFloor: z.number().int().min(0),
}).strict();

export type CurrentCursorResponse = z.infer<typeof CurrentCursorResponseSchema>;

export const CursorGoneErrorSchema = z.object({
  error: z.literal('cursor-gone'),
  currentCursor: z.number().int().min(0),
}).strict();

export type CursorGoneError = z.infer<typeof CursorGoneErrorSchema>;

/**
 * Account KV changes are recorded in one coalesced row per key family (`entityId`), so a reader
 * catching up can tell which families changed since its cursor: the hint of a row only names the
 * keys of that row's last write, and a single row let a presence write hide an earlier task write.
 * Keys of other families keep the historical `self` row.
 */
export const ACCOUNT_KV_CHANGE_FAMILIES = ['presence', 'task', 'agentprofile', 'agent'] as const;
export type AccountKvChangeFamily = (typeof ACCOUNT_KV_CHANGE_FAMILIES)[number] | 'self';

export function accountKvChangeFamily(key: string): AccountKvChangeFamily {
  const head = key.split('/', 1)[0] ?? '';
  return (ACCOUNT_KV_CHANGE_FAMILIES as readonly string[]).includes(head) && key.includes('/')
    ? head as AccountKvChangeFamily
    : 'self';
}

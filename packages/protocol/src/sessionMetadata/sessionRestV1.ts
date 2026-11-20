import { z } from 'zod';

/**
 * Why a Session was stopped when stopping it was not the user's own decision. `happier session
 * stop --reason <reason>` writes `{ v: 1, reason, at }` under this key once the stop is confirmed
 * (`isSessionStopConfirmed`), including for a Session that was already stopped. A stop without a
 * reason writes nothing, so a Session the user stopped carries no newer rest.
 *
 * The rest holds only until the Session next starts: it is resting while it is not running and
 * `at` is no older than the runner's `lifecycleStateSince`, which every start and resume rewrites.
 * Nobody clears the record. The native Apple client reads this rule in `Session.isResting`.
 */
export const SESSION_REST_METADATA_KEY = 'sessionRestV1' as const;

/** Closed: only automatic stops have a reason. */
export const SessionRestReasonSchema = z.enum(['idle']);
export type SessionRestReason = z.infer<typeof SessionRestReasonSchema>;

export const SessionRestV1Schema = z.object({
  v: z.literal(1),
  reason: SessionRestReasonSchema,
  at: z.number().int().nonnegative(),
}).strict();
export type SessionRestV1 = z.infer<typeof SessionRestV1Schema>;

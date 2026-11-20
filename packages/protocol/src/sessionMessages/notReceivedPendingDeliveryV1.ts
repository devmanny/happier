import { z } from 'zod';

import { PendingLocalIdSchema } from './pendingLocalId.js';

/**
 * The current session runner reports, from its provider's own evidence, that a row whose provider
 * effect was possible (a replaced runner's uncertain claim) never reached the provider. The server
 * returns that exact row to its place in line. Advertised by Pending Input protocol v3.
 */
export const NOT_RECEIVED_PENDING_DELIVERY_EVENT_V1 = 'pending-delivery-not-received-v1' as const;

const NotReceivedPendingDeliveryIdentityV1Schema = z.string().refine(
  (value) => value.trim().length > 0,
  { message: 'Identity must not be blank' },
);

export const NotReceivedPendingDeliveryRequestV1Schema = z.object({
  v: z.literal(1),
  sessionId: NotReceivedPendingDeliveryIdentityV1Schema,
  localId: PendingLocalIdSchema,
}).strict();

export type NotReceivedPendingDeliveryRequestV1 = z.infer<typeof NotReceivedPendingDeliveryRequestV1Schema>;

const PendingCountV1Schema = z.number().int().nonnegative();

export const NotReceivedPendingDeliveryResponseV1Schema = z.union([
  z.object({
    ok: z.literal(true),
    didRequeue: z.boolean(),
    pendingCount: PendingCountV1Schema,
    pendingBlockedCount: PendingCountV1Schema,
    pendingVersion: PendingCountV1Schema,
  }).strict(),
  z.object({
    ok: z.literal(false),
    error: z.enum([
      'session-not-found',
      'forbidden',
      'invalid-params',
      'not-found',
      'delivery-settlement-conflict',
      'internal',
    ]),
  }).strict(),
  z.object({
    ok: z.literal(false),
    error: z.literal('transaction-unavailable'),
    retryAfterMs: z.number().int().nonnegative(),
  }).strict(),
]);

export type NotReceivedPendingDeliveryResponseV1 = z.infer<typeof NotReceivedPendingDeliveryResponseV1Schema>;

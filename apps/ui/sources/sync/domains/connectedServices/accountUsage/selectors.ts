import {
  ProviderAccountUsageRecordIdSchema,
  isConnectedServiceCredentialHealthStatusUsable,
  type ConnectedServiceQuotaSnapshotV1,
  type ProviderAccountUsageSnapshotV1,
} from '@happier-dev/protocol';

import type { ConnectedServiceQuotaProfileRefProvenance } from '@/sync/domains/connectedServices/connectedServiceQuotaGauge';
import { resolveConnectedServiceCredentialHealthStatus } from '@/sync/domains/connectedServices/resolveConnectedServiceCredentialHealthStatus';

import {
  projectProviderAccountUsageToNativeDisplaySnapshot,
} from './projection';

export type ProviderUsageDisplayConnectedServiceProfileRef = Readonly<{
  serviceId: string;
  profileId: string;
  credentialHealthStatus?: unknown;
  provenance: ConnectedServiceQuotaProfileRefProvenance;
}>;

export type ProviderUsageDisplaySnapshotSource =
  | Readonly<{
    kind: 'connected_service_quota_view';
    snapshot: ConnectedServiceQuotaSnapshotV1;
    connectedServiceRefProvenance: ConnectedServiceQuotaProfileRefProvenance | null;
  }>
  | Readonly<{
    kind: 'account_usage';
    snapshot: ConnectedServiceQuotaSnapshotV1;
    accountUsageSnapshot: ProviderAccountUsageSnapshotV1;
    connectedServiceRefProvenance: ConnectedServiceQuotaProfileRefProvenance;
  }>;

function selectCandidateAccountUsageSnapshots(params: Readonly<{
  metadataRecordIds: ReadonlyArray<string>;
  accountUsageSnapshotsByRecordId: Readonly<Record<string, ProviderAccountUsageSnapshotV1 | null | undefined>>;
}>): ProviderAccountUsageSnapshotV1[] {
  const candidates: ProviderAccountUsageSnapshotV1[] = [];
  const seenRecordIds = new Set<string>();
  for (const rawRecordId of params.metadataRecordIds) {
    const parsedRecordId = ProviderAccountUsageRecordIdSchema.safeParse(rawRecordId);
    if (!parsedRecordId.success || seenRecordIds.has(parsedRecordId.data)) continue;
    seenRecordIds.add(parsedRecordId.data);
    const snapshot = params.accountUsageSnapshotsByRecordId[parsedRecordId.data] ?? null;
    if (!snapshot) continue;
    candidates.push(snapshot);
  }
  // The daemon lists the account the session runs on now last (`providerAccountUsageRefsV1.ts`).
  // An earlier account's record can be fresher, since its other sessions keep reading it.
  return candidates.reverse();
}

function isProviderUsageDisplayCandidateForProvider(
  snapshot: ProviderAccountUsageSnapshotV1,
  providerId: string | null,
): boolean {
  const normalizedProviderId = providerId?.trim() ?? '';
  return normalizedProviderId.length === 0 || snapshot.providerId === normalizedProviderId;
}

function selectNativeAccountUsageDisplaySnapshot(params: Readonly<{
  providerId: string | null;
  candidates: ReadonlyArray<ProviderAccountUsageSnapshotV1>;
  connectedServiceRefProvenance: ConnectedServiceQuotaProfileRefProvenance;
}>): ProviderUsageDisplaySnapshotSource | null {
  for (const candidate of params.candidates) {
    if (!isProviderUsageDisplayCandidateForProvider(candidate, params.providerId)) continue;
    const projected = projectProviderAccountUsageToNativeDisplaySnapshot({
      snapshot: candidate,
      providerId: params.providerId,
    });
    if (!projected) continue;
    return {
      kind: 'account_usage',
      snapshot: projected,
      accountUsageSnapshot: candidate,
      connectedServiceRefProvenance: params.connectedServiceRefProvenance,
    };
  }
  return null;
}

export function selectProviderUsageDisplaySnapshot(params: Readonly<{
  providerId: string | null;
  metadataRecordIds: ReadonlyArray<string>;
  accountUsageSnapshotsByRecordId: Readonly<Record<string, ProviderAccountUsageSnapshotV1 | null | undefined>>;
  connectedServiceProfileRef: ProviderUsageDisplayConnectedServiceProfileRef | null;
  connectedServiceQuotaView: ConnectedServiceQuotaSnapshotV1 | null;
}>): ProviderUsageDisplaySnapshotSource | null {
  const candidates = selectCandidateAccountUsageSnapshots(params);
  const connectedRef = params.connectedServiceProfileRef;
  if (connectedRef) {
    if (
      connectedRef.credentialHealthStatus !== undefined
      && !isConnectedServiceCredentialHealthStatusUsable(
        resolveConnectedServiceCredentialHealthStatus(connectedRef.credentialHealthStatus),
      )
    ) {
      return null;
    }
    if (params.connectedServiceQuotaView) {
      return {
        kind: 'connected_service_quota_view',
        snapshot: params.connectedServiceQuotaView,
        connectedServiceRefProvenance: connectedRef.provenance,
      };
    }
    if (connectedRef.provenance === 'published_quota_ref') {
      const nativeSource = selectNativeAccountUsageDisplaySnapshot({
        providerId: params.providerId,
        candidates,
        connectedServiceRefProvenance: connectedRef.provenance,
      });
      if (nativeSource) return nativeSource;
    }
    return null;
  }

  const nativeSource = selectNativeAccountUsageDisplaySnapshot({
    providerId: params.providerId,
    candidates,
    connectedServiceRefProvenance: 'published_quota_ref',
  });
  if (nativeSource) return nativeSource;
  return params.connectedServiceQuotaView
    ? {
      kind: 'connected_service_quota_view',
      snapshot: params.connectedServiceQuotaView,
      connectedServiceRefProvenance: null,
    }
    : null;
}

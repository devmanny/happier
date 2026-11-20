import Foundation

/// How much of the provider account's usage limits is left (`ProviderAccountUsageSnapshotV1`,
/// `connectedServiceQuotaGauge.ts`): the 5-hour, weekly… meters the daemon reads from the
/// provider and publishes per session (`metadata.providerAccountUsageRefsV1`).
public struct ProviderUsage: Equatable, Sendable {
    public struct Meter: Identifiable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let usedPercent: Double
        public var remainingPercent: Double { 100 - usedPercent }
        public let resetsAt: Date?
        public let windowDuration: TimeInterval?
        /// Set when the limit applies to one model only.
        public let modelId: String?
        /// Usage and rate limits rank; balances and the like are only listed.
        public let isLimit: Bool
    }

    public let providerId: String?
    public let planLabel: String?
    public let meters: [Meter]
    public let fetchedAt: Date?
    /// How long the provider's numbers hold before the daemon reads them again.
    public let staleAfter: TimeInterval?

    public init?(snapshot: JSONValue) {
        guard let rows = snapshot["meters"]?.arrayValue else { return nil }
        providerId = snapshot["providerId"]?.stringValue
        planLabel = snapshot["planLabel"]?.stringValue
        fetchedAt = snapshot["fetchedAtMs"]?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) }
        staleAfter = snapshot["staleAfterMs"]?.doubleValue.map { $0 / 1000 }
        meters = rows.compactMap(Self.meter)
    }

    /// The limits a session ran into (`lastRuntimeIssue.usageLimit`,
    /// `deriveConnectedServiceQuotaSnapshotFromRuntimeIssue`): what the gauge shows when the daemon
    /// published no usage for the session, as with Claude on its own login.
    public init?(runtimeIssue: JSONValue) {
        guard let limit = runtimeIssue["usageLimit"], limit.objectValue != nil else { return nil }
        let category = limit["limitCategory"]?.stringValue
        guard category == nil || category == "usage_limit" || category == "rate_limit" else { return nil }
        let reset = limit["resetAtMs"]?.doubleValue
        var windows = limit["allWindows"]?.arrayValue ?? []
        if windows.isEmpty, let id = limit["effectiveMeterId"]?.stringValue, let remaining = limit["effectiveRemainingPct"]?.doubleValue {
            windows = [["meterId": .string(id), "scope": .string(id), "remainingPct": .number(remaining)]]
        } else if windows.isEmpty, let utilization = limit["utilization"]?.doubleValue {
            let id = limit["providerLimitId"]?.stringValue ?? limit["effectiveMeterId"]?.stringValue ?? "usage_limit"
            windows = [["meterId": .string(id), "scope": .string(id), "remainingPct": .number(100 - utilization)]]
        }
        let meters = windows.compactMap { window -> Meter? in
            guard let id = window["meterId"]?.stringValue, let remaining = window["remainingPct"]?.doubleValue,
                  window["status"]?.stringValue.map({ $0 == "ok" }) ?? true else { return nil }
            let resetMs = window["resetAtMs"]?.doubleValue ?? (windows.count == 1 ? reset : nil)
            return Meter(id: id, label: window["scope"]?.stringValue ?? id, usedPercent: min(max(100 - remaining, 0), 100),
                         resetsAt: resetMs.map { Date(timeIntervalSince1970: $0 / 1000) }, windowDuration: nil, modelId: nil, isLimit: true)
        }
        guard !meters.isEmpty else { return nil }
        providerId = runtimeIssue["provider"]?.stringValue
        planLabel = limit["planType"]?.stringValue
        self.meters = meters
        fetchedAt = nil
        staleAfter = nil
    }

    /// The meter with the least left among the limits that apply to `modelId` (the gauge's
    /// default `most_constrained` window mode).
    public func mostConstrained(modelId: String?) -> Meter? {
        meters
            .filter { $0.isLimit && ($0.modelId == nil || $0.modelId == modelId) }
            .min { $0.remainingPercent < $1.remainingPercent }
    }

    /// The weekly account or model limit shown by the inner toolbar ring.
    public func weeklyLimit(modelId: String?) -> Meter? {
        meters.filter { meter in
            guard meter.isLimit, meter.modelId == nil || meter.modelId == modelId else { return false }
            if let duration = meter.windowDuration { return duration == 7 * 24 * 60 * 60 }
            // Runtime usage-limit windows identify the period by provider limit id.
            return meter.id == "weekly" || meter.id == "seven_day" || meter.id.hasPrefix("seven_day_")
        }
        .min { $0.remainingPercent < $1.remainingPercent }
    }

    public static func recordIds(in metadata: JSONValue) -> [String] {
        (metadata["providerAccountUsageRefsV1"]?["recordIds"]?.arrayValue ?? []).compactMap(\.stringValue)
    }

    /// `deriveQuotaUtilizationPct.ts`: utilization, else used %, else what remains, else used/limit.
    private static func meter(_ raw: JSONValue) -> Meter? {
        guard let id = raw["meterId"]?.stringValue, raw["status"]?.stringValue != "unavailable" else { return nil }
        let used: Double?
        if let utilization = raw["utilizationPct"]?.doubleValue {
            used = utilization
        } else if let usedPct = raw["usedPct"]?.doubleValue {
            used = usedPct
        } else if let remaining = raw["remainingPct"]?.doubleValue ?? raw["details"]?["remainingPct"]?.doubleValue {
            used = 100 - remaining
        } else if let count = raw["used"]?.doubleValue, let limit = raw["limit"]?.doubleValue, limit > 0 {
            used = count / limit * 100
        } else {
            used = nil
        }
        guard let used else { return nil }
        let category = raw["details"]?["limitCategory"]?.stringValue
        let reset = raw["resetsAt"]?.doubleValue ?? raw["resetAtMs"]?.doubleValue
        return Meter(
            id: id, label: raw["label"]?.stringValue ?? id, usedPercent: min(max(used, 0), 100),
            resetsAt: reset.map { Date(timeIntervalSince1970: $0 / 1000) },
            windowDuration: raw["windowDurationMs"]?.doubleValue.map { $0 / 1000 },
            modelId: raw["modelId"]?.stringValue,
            isLimit: category == nil || category == "usage_limit" || category == "rate_limit")
    }
}

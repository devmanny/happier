import Foundation
import Testing
@testable import HappierKit

@Suite struct ProviderUsageTests {
    /// Sealed by `sealAccountScopedBlobCiphertext` (packages/protocol) with machineKey 1…32 and a nonce of 7s.
    private let sealed = "oQYHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwdaw8/rh0bD16/8rolJr0r5bhF3w5W13jKJjhaP6Z7vNxVkdkwp4eRmBhWFAnk6KPJ1S4IISXaSyAsWRmxWWzp5PIDEEQ=="

    @Test func opensAnAccountScopedSnapshot() throws {
        let machineKey = Data((1...32).map(UInt8.init))
        let value = AccountScopedBlob.open(sealed, kind: .providerAccountUsageSnapshot, machineKey: machineKey)
        #expect(value?["meters"]?[0]?["remainingPct"]?.doubleValue == 97)
        #expect(AccountScopedBlob.open(sealed, kind: .providerAccountUsageSnapshot, machineKey: Data(repeating: 9, count: 32)) == nil)
    }

    private func meter(_ id: String, _ fields: [String: JSONValue]) -> JSONValue {
        var meter: [String: JSONValue] = ["meterId": .string(id), "label": .string(id), "used": .null, "limit": .null,
                                          "unit": "percent", "utilizationPct": .null, "resetsAt": .null, "status": "ok"]
        meter.merge(fields) { $1 }
        return .object(meter)
    }

    @Test func picksTheMostConstrainedUsableMeter() throws {
        let snapshot: JSONValue = ["v": 1, "providerId": "codex", "planLabel": "pro", "fetchedAtMs": 1_000, "staleAfterMs": 300_000, "meters": [
            meter("weekly", ["remainingPct": 97, "windowDurationMs": 604_800_000, "resetsAt": 2_000_000]),
            meter("session", ["utilizationPct": 60, "windowDurationMs": 18_000_000]),
            meter("broken", ["utilizationPct": 99, "status": "unavailable"]),
            meter("opus", ["utilizationPct": 95, "modelId": "claude-opus"]),
            meter("credits", ["utilizationPct": 90, "details": ["limitCategory": "credit_balance"]]),
        ]]
        let usage = try #require(ProviderUsage(snapshot: snapshot))
        #expect(usage.planLabel == "pro")
        #expect(usage.meters.map(\.id) == ["weekly", "session", "opus", "credits"])
        let weekly = usage.meters[0]
        #expect(weekly.remainingPercent == 97 && weekly.usedPercent == 3)
        #expect(weekly.resetsAt == Date(timeIntervalSince1970: 2_000))
        #expect(usage.mostConstrained(modelId: "gpt-6")?.id == "session")
        #expect(usage.mostConstrained(modelId: "claude-opus")?.id == "opus")
    }

    @Test func recordIdsComeFromSessionMetadata() {
        let metadata: JSONValue = ["providerAccountUsageRefsV1": ["v": 1, "recordIds": ["paug_v1_a", "paug_v1_b"], "updatedAtMs": 5]]
        #expect(ProviderUsage.recordIds(in: metadata) == ["paug_v1_a", "paug_v1_b"])
        #expect(ProviderUsage.recordIds(in: ["other": 1]).isEmpty)
    }

    @Test func weeklyRingUsesTheApplicableWeeklyLimit() throws {
        let usage = try #require(ProviderUsage(snapshot: ["meters": [
            meter("five_hour", ["utilizationPct": 99, "windowDurationMs": 18_000_000]),
            meter("weekly", ["utilizationPct": 30, "windowDurationMs": 604_800_000]),
            meter("weekly-opus", ["utilizationPct": 80, "windowDurationMs": 604_800_000, "modelId": "claude-opus"]),
            meter("weekly-credits", ["utilizationPct": 95, "windowDurationMs": 604_800_000,
                                      "details": ["limitCategory": "credit_balance"]]),
        ]]))
        #expect(usage.weeklyLimit(modelId: "gpt-6")?.id == "weekly")
        #expect(usage.weeklyLimit(modelId: "claude-opus")?.id == "weekly-opus")

        let onlyShortWindow = try #require(ProviderUsage(snapshot: ["meters": [
            meter("five_hour", ["utilizationPct": 99, "windowDurationMs": 18_000_000]),
        ]]))
        #expect(onlyShortWindow.weeklyLimit(modelId: nil) == nil)
    }

    @Test func weeklyRingRecognizesRuntimeLimitWindows() throws {
        let usage = try #require(ProviderUsage(runtimeIssue: ["usageLimit": ["allWindows": [
            ["meterId": "five_hour", "remainingPct": 0],
            ["meterId": "seven_day", "remainingPct": 40],
        ]]]))
        #expect(usage.weeklyLimit(modelId: nil)?.id == "seven_day")
    }

    @Test func aUsageLimitHitFillsInWhenNothingWasPublished() throws {
        let windows: JSONValue = ["provider": "claude", "usageLimit": [
            "v": 1, "resetAtMs": 3_000_000, "retryAfterMs": .null, "quotaScope": "account", "recoverability": "wait",
            "allWindows": [["meterId": "five_hour", "scope": "5-hour", "remainingPct": 0, "resetAtMs": 3_000_000],
                           ["meterId": "seven_day", "scope": "Weekly", "remainingPct": 40]],
        ]]
        let usage = try #require(ProviderUsage(runtimeIssue: windows))
        #expect(usage.meters.map(\.label) == ["5-hour", "Weekly"])
        #expect(usage.mostConstrained(modelId: nil)?.id == "five_hour")
        #expect(usage.meters[0].resetsAt == Date(timeIntervalSince1970: 3_000))

        let utilization: JSONValue = ["usageLimit": ["v": 1, "resetAtMs": .null, "retryAfterMs": .null, "quotaScope": "account",
                                                     "recoverability": "wait", "utilization": 92, "providerLimitId": "weekly"]]
        #expect(ProviderUsage(runtimeIssue: utilization)?.meters.first?.remainingPercent == 8)

        let credits: JSONValue = ["usageLimit": ["v": 1, "resetAtMs": .null, "retryAfterMs": .null, "quotaScope": "account",
                                                 "recoverability": "manual", "utilization": 92, "limitCategory": "credit_balance"]]
        #expect(ProviderUsage(runtimeIssue: credits) == nil)
        #expect(ProviderUsage(runtimeIssue: ["code": "other"]) == nil)
    }
}

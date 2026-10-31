import Foundation
import Testing
@testable import HappierKit

/// What the "Working Now", "Recent" and "Usage" widgets show, with the session list's own states.
@MainActor
struct ActivitySnapshotTests {
    private let server = URL(string: "https://happier.nomada.cloud")!
    private let now = Date(timeIntervalSince1970: 10_000)

    private func session(_ id: String, updated: Double, thinking: Bool = false, unread: Bool = false,
                         permission: Bool = false, active: Bool = true) throws -> Session {
        var session = try Session(row: ["id": .string(id), "seq": 0, "createdAt": 1, "updatedAt": .number(updated * 1000),
                                        "active": .bool(active), "activeAt": .number(updated * 1000), "encryptionMode": "plain",
                                        "metadata": .string("{\"flavor\":\"claude\",\"path\":\"/w/proj-\(id)\",\"summary\":{\"text\":\"T-\(id)\",\"updatedAt\":1}}"),
                                        "metadataVersion": 1, "agentStateVersion": 0], keys: nil)
        session.thinking = thinking
        session.thinkingAt = thinking ? Date(timeIntervalSince1970: updated) : nil
        if unread { session.unreadSince = Date(timeIntervalSince1970: updated) }
        if permission { session.pendingPermissionRequestCount = 1 }
        return session
    }

    @Test func listsWhatIsWorkingAndTheRecentOnesWithTheirState() throws {
        let sessions = [
            try session("a", updated: 9_990, thinking: true),
            try session("b", updated: 9_950, permission: true),
            try session("c", updated: 9_900, unread: true),
            try session("d", updated: 9_800),
            try session("e", updated: 9_995, thinking: true),
            try session("f", updated: 9_000, active: false),
        ]
        let snapshot = ActivitySnapshot(sessions: sessions, usage: [], server: server, now: now)
        // Working: started longest ago first, timed from when it began.
        #expect(snapshot.working.map(\.sessionId) == ["a", "e"])
        #expect(snapshot.working[0].since == Date(timeIntervalSince1970: 9_990))
        // Recent: in the list's order, each with the state the list shows.
        #expect(snapshot.recent.map(\.state) == [.working, .waiting, .unread, .idle, .working, .offline])
        #expect(snapshot.recent[0].folder == "proj-a")
        #expect(snapshot.recent[0].link == SessionLink(sessionId: "a", server: server)?.nativeURL)
    }

    @Test func keepsTheTightestLimitOfEachProviderFromItsNewestReading() throws {
        func usage(_ provider: String, fetched: Double, meters: [(String, Double)]) throws -> ProviderUsage {
            try #require(ProviderUsage(snapshot: [
                "providerId": .string(provider), "fetchedAtMs": .number(fetched * 1000),
                "meters": .array(meters.map { ["meterId": .string($0.0), "usedPct": .number($0.1)] }),
            ]))
        }
        let readings = [
            try usage("claude", fetched: 100, meters: [("five_hour", 90)]),
            try usage("claude", fetched: 200, meters: [("five_hour", 40), ("weekly", 70)]),
            try usage("codex", fetched: 150, meters: [("weekly", 20)]),
        ]
        let snapshot = ActivitySnapshot(sessions: [], usage: readings, server: server, now: now)
        #expect(snapshot.usage.map(\.providerId) == ["claude", "codex"])
        #expect(snapshot.usage[0].usedPercent == 70)
        #expect(snapshot.usage[0].meter == "weekly")
        #expect(snapshot.usage[0].fetchedAt == Date(timeIntervalSince1970: 200))
    }

    /// A limit of one model (one you may not even use) isn't the account's: the widget shows what
    /// the chat's usage ring shows, the tightest account-wide limit.
    @Test func ignoresAModelOnlyLimitLikeTheChatRing() throws {
        let reading = try #require(ProviderUsage(snapshot: [
            "providerId": "claude", "fetchedAtMs": 1_000,
            "meters": [
                ["meterId": "weekly", "usedPct": 12],
                ["meterId": "five_hour", "usedPct": 30],
                ["meterId": "weekly_opus", "usedPct": 100, "modelId": "claude-opus-4"],
            ],
        ]))
        let snapshot = ActivitySnapshot(sessions: [], usage: [reading], server: server, now: now)
        #expect(snapshot.usage.first?.meter == "five_hour")
        #expect(snapshot.usage.first?.usedPercent == 30)
    }
}

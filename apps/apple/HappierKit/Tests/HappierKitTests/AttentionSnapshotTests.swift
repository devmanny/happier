import Foundation
import Testing
@testable import HappierKit

/// What the Home Screen widget shows: the sessions waiting on you, most urgent first.
@MainActor
struct AttentionSnapshotTests {
    private let server = URL(string: "https://happier.nomada.cloud")!

    private func session(_ id: String, title: String, updated: Double, unread: Bool = false, request: String? = nil) throws -> Session {
        var session = try Session(row: ["id": .string(id), "seq": 0, "createdAt": 1, "updatedAt": .number(updated), "active": true,
                                        "activeAt": .number(updated), "encryptionMode": "plain",
                                        "metadata": .string("{\"flavor\":\"claude\",\"summary\":{\"text\":\"\(title)\",\"updatedAt\":1}}"),
                                        "metadataVersion": 1, "agentStateVersion": 1], keys: nil)
        if unread { session.unreadSince = Date(timeIntervalSince1970: updated / 1000) }
        if let request {
            session.agentState = ["requests": [request: ["tool": "Bash", "arguments": [:], "createdAt": .number(updated)]]]
        }
        return session
    }

    @Test func waitingForYouComesFirstThenUnreadNewestFirst() throws {
        let sessions = [
            try session("old-unread", title: "Old", updated: 1_000, unread: true),
            try session("quiet", title: "Quiet", updated: 9_000),
            try session("approval", title: "Deploy", updated: 2_000, request: "r1"),
            try session("new-unread", title: "New", updated: 5_000, unread: true),
        ]
        let snapshot = AttentionSnapshot(sessions: sessions, server: server, limit: 6)
        #expect(snapshot.items.map(\.sessionId) == ["approval", "new-unread", "old-unread"])
        #expect(snapshot.total == 3)
        #expect(snapshot.items[0].reason == .waitingForYou)
        #expect(snapshot.items[1].reason == .unread)
        #expect(snapshot.items[0].title == "Deploy")
        #expect(snapshot.items[0].agentId == "claude")
        #expect(snapshot.items[0].link == SessionLink(sessionId: "approval", server: server)?.nativeURL)
    }

    @Test func keepsTheCountBeyondWhatFits() throws {
        let sessions = try (0..<5).map { try session("s\($0)", title: "S\($0)", updated: Double($0) * 1_000, unread: true) }
        let snapshot = AttentionSnapshot(sessions: sessions, server: server, limit: 2)
        #expect(snapshot.items.count == 2)
        #expect(snapshot.total == 5)
    }

    @Test func roundTripsThroughTheSharedStore() throws {
        let defaults = try #require(UserDefaults(suiteName: "attention-\(UUID().uuidString)"))
        #expect(AttentionSnapshot.load(from: defaults) == nil)
        let snapshot = AttentionSnapshot(sessions: [try session("a", title: "A", updated: 1_000, unread: true)], server: server, limit: 3)
        snapshot.save(to: defaults)
        #expect(AttentionSnapshot.load(from: defaults) == snapshot)
    }
}

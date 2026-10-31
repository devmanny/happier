import Foundation
import Testing
@testable import HappierKit

/// Sharing from another app: the share extension leaves the files and a message for a
/// conversation; the app picks them up once and sends them through its normal send.
struct ShareOutboxTests {
    private func temporaryOutbox() -> ShareOutbox {
        ShareOutbox(root: FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString)"))
    }

    @Test func keepsFilesAndMessageUntilTheAppTakesThem() throws {
        let outbox = temporaryOutbox()
        #expect(outbox.pending().isEmpty)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("memo-\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: source)
        try outbox.add(sessionId: "s1", message: "Listen to this", files: [source])

        let deliveries = outbox.pending()
        #expect(deliveries.count == 1)
        let delivery = try #require(deliveries.first)
        #expect(delivery.sessionId == "s1")
        #expect(delivery.message == "Listen to this")
        #expect(delivery.files.map(\.lastPathComponent) == [source.lastPathComponent])
        #expect(try Data(contentsOf: delivery.files[0]) == Data("audio".utf8))

        // Taken once: gone with its files.
        outbox.remove(delivery)
        #expect(outbox.pending().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: delivery.files[0].path))
    }

    @Test func sameNamedFilesDontOverwriteEachOther() throws {
        let outbox = temporaryOutbox()
        let a = FileManager.default.temporaryDirectory.appendingPathComponent("a-\(UUID().uuidString)")
        let b = FileManager.default.temporaryDirectory.appendingPathComponent("b-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: a.appendingPathComponent("IMG.jpg"))
        try Data("two".utf8).write(to: b.appendingPathComponent("IMG.jpg"))
        try outbox.add(sessionId: "s1", message: "", files: [a.appendingPathComponent("IMG.jpg"), b.appendingPathComponent("IMG.jpg")])
        let files = try #require(outbox.pending().first).files
        #expect(Set(files.map { try? Data(contentsOf: $0) }) == [Data("one".utf8), Data("two".utf8)])
    }

    @Test func listsTheConversationsToShareInto() throws {
        let session = try Session(row: ["id": "s1", "seq": 0, "createdAt": 1, "updatedAt": 5_000, "active": true, "activeAt": 5_000,
                                        "encryptionMode": "plain",
                                        "metadata": .string("{\"flavor\":\"codex\",\"path\":\"/Users/m/app\",\"summary\":{\"text\":\"Fix login\",\"updatedAt\":1}}"),
                                        "metadataVersion": 1, "agentStateVersion": 0], keys: nil)
        let defaults = try #require(UserDefaults(suiteName: "share-\(UUID().uuidString)"))
        ShareTargets(sessions: [session]).save(to: defaults)
        let targets = try #require(ShareTargets.load(from: defaults))
        #expect(targets.items == [ShareTargets.Item(sessionId: "s1", title: "Fix login", agentId: "codex", folder: "app",
                                                    date: session.updatedAt)])
    }
}

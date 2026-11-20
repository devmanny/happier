import Foundation
import Testing
@testable import HappierKit

/// The session list kept on disk between launches and brought up to date through `/v2/changes`.
@Suite struct SessionSnapshotTests {
    private func row(_ id: String, seq: Int, archived: Bool = false) -> JSONValue {
        var row: [String: JSONValue] = ["id": .string(id), "seq": .number(Double(seq)), "encryptionMode": "plain", "metadata": #"{"path":"/a"}"#]
        if archived { row["archivedAt"] = 5 }
        return .object(row)
    }

    @Test func survivesARoundTripThroughDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = SessionSnapshotStore(directory: directory, scope: "relay.example/acc 1")
        await store.save(SessionSnapshot(rows: [row("a", seq: 1), row("b", seq: 2)], cursor: 42))
        let loaded = await store.load()
        #expect(loaded?.cursor == 42)
        #expect(loaded?.rows.map { $0["id"]?.stringValue } == ["a", "b"])
        await store.clear()
        #expect(await store.load() == nil)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func changesUpdateAddAndDropRows() {
        let snapshot = SessionSnapshot(rows: [row("a", seq: 1), row("b", seq: 1), row("c", seq: 1)], cursor: 10)
        // "a" changed, "d" is new, "b" was archived, "c" was deleted (no row).
        let next = snapshot.applying(changed: ["a": row("a", seq: 2), "d": row("d", seq: 1), "b": row("b", seq: 2, archived: true)],
                                     removed: ["c"], cursor: 20)
        #expect(next.cursor == 20)
        #expect(Set(next.rows.compactMap { $0["id"]?.stringValue }) == ["a", "d"])
        #expect(next.rows.first { $0["id"] == "a" }?["seq"] == 2)
    }

    @Test func readsChangedSessionIdsFromAChangesPage() {
        let page: JSONValue = ["changes": [
            ["cursor": 11, "kind": "session", "entityId": "s1", "changedAt": 1],
            ["cursor": 12, "kind": "machine", "entityId": "m1", "changedAt": 1],
            ["cursor": 13, "kind": "session", "entityId": "s2", "changedAt": 1],
        ], "nextCursor": 13]
        let parsed = SessionChanges.page(page)
        #expect(parsed.sessionIds == ["s1", "s2"])
        #expect(parsed.nextCursor == 13)
        #expect(parsed.count == 3)
    }
}

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
        #expect(Set(loaded?.rows.compactMap { $0["id"]?.stringValue } ?? []) == ["a", "b"])
        await store.clear()
        #expect(await store.load() == nil)
        try? FileManager.default.removeItem(at: directory)
    }

    private func big(_ id: String, seq: Int, archived: Bool = false) -> JSONValue {
        var row: [String: JSONValue] = ["id": .string(id), "seq": .number(Double(seq)), "encryptionMode": "plain",
                                        "metadata": .string(String(repeating: "m", count: 20_000))]
        if archived { row["archivedAt"] = 5 }
        return .object(row)
    }

    /// Every file under `directory` with its bytes, to tell which a sync wrote.
    private func files(_ directory: URL) -> [String: Data] {
        let root = directory.resolvingSymlinksInPath().path
        let all = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return Dictionary(uniqueKeysWithValues: all.compactMap { url in
            (try? Data(contentsOf: url)).map { (url.resolvingSymlinksInPath().path.replacingOccurrences(of: root, with: ""), $0) }
        })
    }

    /// A changed-only sync (every reconnect) writes the changed sessions and the cursor, not the
    /// whole list: a real row is ~20 KB of encrypted metadata, the list megabytes.
    @Test func aChangedSyncWritesOnlyTheChangedSessions() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionSnapshotStore(directory: directory, scope: "relay.example/acc 1")
        await store.save(SessionSnapshot(rows: (0..<50).map { big("s\($0)", seq: 1) }, cursor: 10))
        let before = files(directory)

        await store.apply(changed: ["s3": big("s3", seq: 2), "new": big("new", seq: 1), "s4": big("s4", seq: 2, archived: true)],
                          removed: ["s7"], cursor: 20)

        let after = files(directory)
        let written = after.filter { before[$0.key] != $0.value }
        #expect(written.count == 3, "s3, new and the cursor: \(written.keys.sorted())")
        #expect(written.values.reduce(0) { $0 + $1.count } < 3 * 21_000)
        #expect(after.count == before.count - 1, "s4 (archived) and s7 (deleted) left, new joined")
        let loaded = try #require(await SessionSnapshotStore(directory: directory, scope: "relay.example/acc 1").load())
        #expect(loaded.cursor == 20)
        #expect(Set(loaded.rows.compactMap { $0["id"]?.stringValue }) == Set((0..<50).map { "s\($0)" } + ["new"]).subtracting(["s4", "s7"]))
        #expect(loaded.rows.first { $0["id"] == "s3" }?["seq"] == 2)
    }

    /// A full sync (pull to refresh, an expired cursor) rewrites only the sessions that differ and
    /// drops the ones no longer listed.
    @Test func aFullSyncWritesOnlyWhatDiffers() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionSnapshotStore(directory: directory, scope: "s")
        await store.save(SessionSnapshot(rows: (0..<20).map { big("s\($0)", seq: 1) }, cursor: 10))
        let before = files(directory)
        await store.save(SessionSnapshot(rows: (1..<20).map { big("s\($0)", seq: $0 == 5 ? 2 : 1) }, cursor: 30))
        let after = files(directory)
        #expect(after.filter { before[$0.key] != $0.value }.count == 2, "s5 and the cursor")
        #expect(after.count == before.count - 1)
        #expect(await store.load()?.rows.count == 19)
        #expect(await store.load()?.cursor == 30)
    }

    /// The sessions are written before the cursor: a sync cut off between the two leaves the old
    /// cursor, so the next sync fetches those changes again instead of skipping them.
    @Test func sessionsWithoutTheirCursorKeepTheOldOne() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionSnapshotStore(directory: directory, scope: "s")
        await store.save(SessionSnapshot(rows: [big("a", seq: 1)], cursor: 10))
        let cursorFile = try #require(files(directory).first { $0.value.count < 100 }?.key)
        let oldCursor = try Data(contentsOf: directory.appending(path: cursorFile))
        await store.apply(changed: ["a": big("a", seq: 2)], removed: [], cursor: 20)
        // The app killed after the session file, before the cursor.
        try oldCursor.write(to: directory.appending(path: cursorFile))
        let loaded = await SessionSnapshotStore(directory: directory, scope: "s").load()
        #expect(loaded?.cursor == 10)
        await store.clear()
        #expect(await store.load() == nil)
        #expect(files(directory).isEmpty)
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

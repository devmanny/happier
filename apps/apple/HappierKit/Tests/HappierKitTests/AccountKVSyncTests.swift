import Foundation
import Testing
@testable import HappierKit

/// Live task, agent and memory updates from the relay's `kv-batch-update` socket event, and the
/// catch-up through the account's change cursor after a reconnect.
@Suite struct AccountKVSyncTests {
    static let machineKey = Data((0..<32).map { UInt8($0) })

    static func task(_ id: String, title: String) throws -> String {
        try AgentTaskTests.task(["id": .string(id), "title": .string(title)]).sealed(machineKey: machineKey)
    }

    @Test func readsTheChangedKeysValuesAndVersionsFromTheSocketEvent() {
        let body: JSONValue = ["t": "kv-batch-update", "changes": [
            ["key": "task/t1", "value": "abc", "version": 3],
            ["key": "task/t2", "value": .null, "version": 4],
        ]]
        #expect(AccountKVSync.changes(fromUpdate: body) == [
            .init(key: "task/t1", value: "abc", version: 3), .init(key: "task/t2", value: nil, version: 4),
        ])
        #expect(AccountKVSync.changes(fromUpdate: ["t": "update-session"]).isEmpty)
    }

    @Test func aChangesPageSaysWhetherTheKVStoreChangedAndWhereToContinue() {
        let page = AccountKVSync.page(["changes": [
            ["cursor": 10, "kind": "session", "entityId": "s1"],
            ["cursor": 12, "kind": "kv", "entityId": "self", "hint": ["keys": ["task/t1"]]],
        ], "nextCursor": 12])
        #expect(page.touchedKV)
        #expect(page.nextCursor == 12)
        #expect(!AccountKVSync.page(["changes": [["cursor": 3, "kind": "session", "entityId": "s1"]], "nextCursor": 3]).touchedKV)
    }

    @Test func aPageSaysWhichKeyFamiliesChangedSoOnlyThoseAreReadAgain() {
        let page = AccountKVSync.page(["changes": [
            ["cursor": 10, "kind": "kv", "entityId": "presence", "hint": ["keys": ["presence/s1"]]],
            ["cursor": 11, "kind": "kv", "entityId": "task", "hint": ["keys": ["task/t1"]]],
        ], "nextCursor": 11])
        #expect(page.refresh == AccountKVSync.Refresh(tasks: true, profiles: false, memory: false))
        // Presence alone: nothing to read again.
        #expect(AccountKVSync.page(["changes": [["cursor": 3, "kind": "kv", "entityId": "presence"]], "nextCursor": 3]).refresh == .none)
        // Agent memory and legacy profile keys share the agent family.
        #expect(AccountKVSync.page(["changes": [["cursor": 4, "kind": "kv", "entityId": "agent"]], "nextCursor": 4]).refresh
            == AccountKVSync.Refresh(tasks: false, profiles: true, memory: true))
        // The historical single row (older relays) or an unknown family: everything, as before.
        #expect(AccountKVSync.page(["changes": [["cursor": 5, "kind": "kv", "entityId": "self"]], "nextCursor": 5]).refresh == .all)
        #expect(AccountKVSync.page(["changes": [["cursor": 6, "kind": "kv", "entityId": "later"]], "nextCursor": 6]).refresh == .all)
    }

    @MainActor @Test func appliesTaskChangesInPlaceAndIgnoresOlderVersions() throws {
        let store = HappierStore(server: URL(string: "http://127.0.0.1:1")!)
        store.applyKVChanges([
            .init(key: "task/t1", value: try Self.task("t1", title: "Primera"), version: 2),
            .init(key: "task/t2", value: try Self.task("t2", title: "Segunda"), version: 0),
        ], machineKey: Self.machineKey)
        #expect(store.tasks.map(\.title).sorted() == ["Primera", "Segunda"])

        // An echo of an older write doesn't undo a newer one; a deletion removes it.
        store.applyKVChanges([
            .init(key: "task/t1", value: try Self.task("t1", title: "Vieja"), version: 1),
            .init(key: "task/t2", value: nil, version: 1),
        ], machineKey: Self.machineKey)
        #expect(store.tasks.map(\.title) == ["Primera"])
        #expect(store.task(id: "t1")?.version == 2)
    }

    @MainActor @Test func appliesMemoryChangesOnlyToAMemoryThatIsLoaded() throws {
        let store = HappierStore(server: URL(string: "http://127.0.0.1:1")!)
        let note = try AgentMemoryTests.sealed(["v": 1, "id": "n1", "title": "Manny", "markdown": "Hola", "updatedAt": 9])
        store.applyKVChanges([.init(key: "agent/a1/note/n1", value: note, version: 0)], machineKey: AgentMemoryTests.machineKey)
        #expect(store.agentMemories["a1"] == nil)

        store.setAgentMemoryForTests(AgentMemory(), agentId: "a1")
        store.applyKVChanges([.init(key: "agent/a1/note/n1", value: note, version: 0)], machineKey: AgentMemoryTests.machineKey)
        #expect(store.agentMemories["a1"]?.notes.map(\.title) == ["Manny"])
        store.applyKVChanges([.init(key: "agent/a1/note/n1", value: nil, version: 1)], machineKey: AgentMemoryTests.machineKey)
        #expect(store.agentMemories["a1"]?.notes.isEmpty == true)
    }
}

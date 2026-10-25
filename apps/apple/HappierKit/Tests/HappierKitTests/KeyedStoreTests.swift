import Foundation
import Observation
import Testing
@testable import HappierKit

@MainActor
@Suite struct KeyedStoreTests {
    private func observe(_ read: @escaping () -> Void) -> () -> Bool {
        final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        withObservationTracking(read) { flag.fired = true }
        return { flag.fired }
    }

    @Test func readingOneEntryIgnoresTheOthers() {
        let store = KeyedStore<Int>()
        store["a"] = 1
        store["b"] = 1
        let fired = observe { _ = store["a"] }
        store["b"] = 2
        store["a"] = 1
        #expect(!fired())
        store["a"] = 2
        #expect(fired())
    }

    /// "Same" only decides whether to tell readers; the update itself is always kept. A session's
    /// last activity time was dropped this way while its own `==` didn't look at it.
    @Test func anUpdateReadersNeedNotSeeIsStillKept() {
        struct Row: Equatable { var id: String; var note: String }
        let store = KeyedStore<Row>(isSame: { $0.id == $1.id })
        store["a"] = Row(id: "a", note: "old")
        let fired = observe { _ = store["a"] }
        store["a"]?.note = "new"
        #expect(store["a"]?.note == "new")
        #expect(!fired())
    }

    /// Everything a session row shows counts as a change, the last activity time first of all.
    @Test func aSessionWithNewActivityIsADifferentSession() throws {
        let row: JSONValue = ["id": "s", "seq": 1, "createdAt": 1, "updatedAt": 1, "active": false, "encryptionMode": "plain"]
        let session = try Session(row: row, keys: nil)
        var later = session
        later.meaningfulActivityAt = Date(timeIntervalSince1970: 500)
        #expect(later != session)
        var queued = session
        queued.pendingCount = 2
        #expect(queued != session)
        var busy = session
        busy.backgroundActivityCount = 1
        #expect(busy != session)
        // A working agent's heartbeat (every few seconds) only refreshes how recent it is; the
        // rows' own clocks read that, so it redraws nothing by itself.
        var heartbeat = session
        heartbeat.activeAt = Date(timeIntervalSince1970: 900)
        heartbeat.thinkingAt = Date(timeIntervalSince1970: 900)
        heartbeat.latestTurnStatusObservedAt = Date(timeIntervalSince1970: 900)
        #expect(heartbeat == session)
    }

    @Test func listReadersSeeEveryChange() {
        let store = KeyedStore<Int>()
        store["a"] = 1
        let addition = observe { _ = store.values }
        store["c"] = 3
        #expect(addition())
        let edit = observe { _ = store.values }
        store["a"] = 5
        #expect(edit())
    }

    @Test func membershipReadersIgnoreContentChanges() {
        let store = KeyedStore<Int>()
        store["a"] = 1
        let contents = observe { _ = store.keys.contains("a") }
        store["a"] = 2
        #expect(!contents())
        #expect(store.keys.contains("a"))

        let removal = observe { _ = store.keys.contains("a") }
        store["a"] = nil
        #expect(removal())
        #expect(!store.keys.contains("a"))

        let arrival = observe { _ = store.keys.contains("a") }
        store["a"] = 3
        #expect(arrival())
        #expect(store.keys.contains("a"))
    }

    @Test func aMissingEntryIsNoticedWhenItArrives() {
        let store = KeyedStore<Int>()
        let fired = observe { _ = store["later"] }
        store["later"] = 1
        #expect(fired())
        #expect(store["later"] == 1 && store.count == 1)
    }

    @Test func replacingKeepsUnchangedEntriesQuiet() {
        let store = KeyedStore<Int>()
        store.replaceAll(with: ["a": 1, "b": 2])
        let fired = observe { _ = store["a"] }
        store.replaceAll(with: ["a": 1, "b": 3])
        #expect(!fired())
        store.replaceAll(with: ["b": 3])
        #expect(fired() && store["a"] == nil)
    }
}

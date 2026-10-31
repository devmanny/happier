import Foundation
import Testing
@testable import HappierKit

/// Each session drives its own tabs of the integrated browser; users' tabs and other sessions'
/// tabs stay out of reach, and closed or stopped sessions give their tabs back.
@Suite struct DeviceBrowserSessionTabsTests {
    @Test func everyCallBelongsToASession() throws {
        let command = try DeviceBrowserCommand(json: ["op": "tabs", "action": "list", "sessionId": "sess_a"])
        #expect(command == .init(sessionId: "sess_a", request: .tabs(action: .list, tabId: nil, url: nil)))
        #expect(throws: DeviceBrowserError.self) { try DeviceBrowserCommand(json: ["op": "status"]) }
        #expect(throws: DeviceBrowserError.self) { try DeviceBrowserCommand(json: ["op": "status", "sessionId": " "]) }
    }

    @Test func aSessionGetsItsOwnTabOnFirstUseAndKeepsUsingIt() throws {
        var registry = DeviceBrowserTabRegistry()
        let user = registry.open(for: .user)
        let first = try registry.tab(for: "sess_a", tabId: nil, create: true)
        #expect(first.created && first.id != user)
        #expect(try registry.tab(for: "sess_a", tabId: nil, create: true) == .init(id: first.id, created: false))
        let other = try registry.tab(for: "sess_b", tabId: nil, create: true)
        #expect(other.created && other.id != first.id)
        #expect(registry.tabs(of: "sess_a") == [first.id])
        #expect(registry.owner(of: first.id) == .session("sess_a"))
    }

    @Test func aSessionCannotReachTabsItDoesNotOwn() throws {
        var registry = DeviceBrowserTabRegistry()
        let user = registry.open(for: .user)
        let b = try registry.tab(for: "sess_b", tabId: nil, create: true).id
        for foreign in [user, b, "t999"] {
            #expect(throws: DeviceBrowserError(.tabNotFound, "No tab \(foreign)")) { try registry.tab(for: "sess_a", tabId: foreign, create: true) }
            #expect(throws: DeviceBrowserError(.tabNotFound, "No tab \(foreign)")) { try registry.close(foreign, for: "sess_a") }
            #expect(throws: DeviceBrowserError(.tabNotFound, "No tab \(foreign)")) { try registry.select(foreign, for: "sess_a") }
        }
        #expect(throws: DeviceBrowserError.self) { try registry.tab(for: "sess_a", tabId: nil, create: false) }
    }

    @Test func aSessionMayKeepSeveralTabsAndChoosesItsCurrentOne() throws {
        var registry = DeviceBrowserTabRegistry()
        let first = try registry.tab(for: "sess_a", tabId: nil, create: true).id
        let second = registry.open(for: .session("sess_a"))
        #expect(registry.currentTab(of: "sess_a") == second)
        try registry.select(first, for: "sess_a")
        #expect(try registry.tab(for: "sess_a", tabId: nil, create: true).id == first)
        try registry.close(first, for: "sess_a")
        #expect(registry.currentTab(of: "sess_a") == second)
        try registry.close(second, for: "sess_a")
        #expect(registry.currentTab(of: "sess_a") == nil && registry.tabs(of: "sess_a").isEmpty)
    }

    @Test func endedSessionsLoseTheirTabsUnlessTheUserIsLookingAtThem() throws {
        var registry = DeviceBrowserTabRegistry()
        let user = registry.open(for: .user)
        let live = try registry.tab(for: "sess_live", tabId: nil, create: true).id
        let ended = try registry.tab(for: "sess_ended", tabId: nil, create: true).id
        let endedButWatched = try registry.tab(for: "sess_watched", tabId: nil, create: true).id
        let closing = registry.tabsToClose(liveSessionIds: ["sess_live"], visibleTabIds: [endedButWatched])
        #expect(closing == [ended])
        #expect(!closing.contains(user) && !closing.contains(live))
    }

    @MainActor final class EventLog { var events: [String] = [] }

    @MainActor @Test func callsOnOneTabRunInOrderAndOtherTabsRunAlongside() async {
        let queue = KeyedSerialQueue()
        let log = EventLog()
        let slowA = Task { @MainActor in
            await queue.run("t1") {
                log.events.append("a1-start")
                try? await Task.sleep(for: .milliseconds(200))
                log.events.append("a1-end")
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        let nextA = Task { @MainActor in await queue.run("t1") { log.events.append("a2") } }
        let otherTab = Task { @MainActor in await queue.run("t2") { log.events.append("b1") } }
        _ = await (slowA.value, nextA.value, otherTab.value)
        #expect(log.events == ["a1-start", "b1", "a1-end", "a2"])
    }

    @Test func aSessionEndsWhenArchivedStoppedOrGoneAfterBeingSeen() {
        var watch = DeviceBrowserSessionWatch()
        let running = DeviceBrowserSessionWatch.State(active: true, archived: false)
        let idle = DeviceBrowserSessionWatch.State(active: false, archived: false)
        let archived = DeviceBrowserSessionWatch.State(active: true, archived: true)
        // Not known yet (list still loading) or first seen idle: its tab stays.
        let steps: [(String, DeviceBrowserSessionWatch.State?, Bool)] = [
            ("s1", nil, false), ("s1", idle, false), ("s1", running, false), ("s1", idle, true),
            ("s2", running, false), ("s2", archived, true),
            ("s3", running, false), ("s3", nil, true),
        ]
        for (session, state, ended) in steps {
            let result = watch.observe(session, state)
            #expect(result == ended, "\(session) \(String(describing: state))")
        }
    }
}

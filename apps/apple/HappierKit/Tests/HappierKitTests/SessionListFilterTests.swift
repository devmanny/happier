import Foundation
import Testing
@testable import HappierKit

/// The session list's filter: which kinds, states and agents show, and whether only what needs you.
@Suite struct SessionListFilterTests {
    private func session(_ id: String, active: Bool = true, archived: Bool = false, parent: String? = nil, agent: String? = nil,
                         unread: Bool = false, permissions: Int = 0) throws -> Session {
        var metadata: [String: JSONValue] = ["path": "/Users/manny/Projects/app", "name": .string(id)]
        if let parent { metadata["spawnedBySessionV1"] = ["parentSessionId": .string(parent)] }
        if let agent { metadata["agentIdentityV1"] = ["v": 1, "id": .string(agent), "name": .string(agent.capitalized)] }
        var row: [String: JSONValue] = [
            "id": .string(id), "encryptionMode": "plain", "metadataVersion": 1, "active": .bool(active), "updatedAt": 10,
            "metadata": .string(String(decoding: try JSONValue.object(metadata).encoded(), as: UTF8.self)),
            "pendingPermissionRequestCount": .number(Double(permissions)),
        ]
        if archived { row["archivedAt"] = 5 }
        if unread { row["unreadSince"] = 7 }
        return try Session(row: .object(row), keys: nil)
    }

    private func task(_ id: String, threads: [String] = [], occurrenceSession: String? = nil, source: String? = nil,
                      status: String = "todo") -> AgentTask {
        var json: [String: JSONValue] = [
            "v": 1, "id": .string(id), "title": .string(id), "status": .string(status), "assignee": ["kind": "user"],
            "threads": .array(threads.map(JSONValue.string)), "log": [], "createdAt": 0, "updatedAt": 0,
        ]
        if let source { json["source"] = ["kind": "session", "sessionId": .string(source)] }
        if let occurrenceSession {
            json["occurrences"] = [["id": "o1", "startedAt": 1, "status": "completed", "sessionId": .string(occurrenceSession)]]
        }
        return AgentTask(json: .object(json))!
    }

    private func shown(_ filter: SessionListFilter, _ sessions: [Session], tasks: [AgentTask] = []) -> [String] {
        let context = SessionListFilter.Context(tasks: tasks)
        return sessions.filter { filter.includes($0, context: context) }.map(\.id)
    }

    @Test func theDefaultHidesTaskSessionsAndTheArchiveButKeepsTheRest() throws {
        let sessions = [
            try session("normal"), try session("stopped", active: false), try session("child", parent: "normal"),
            try session("worked"), try session("repeat", active: false), try session("archived", archived: true),
        ]
        let tasks = [task("t1", threads: ["worked"]), task("t2", occurrenceSession: "repeat")]
        #expect(shown(.default, sessions, tasks: tasks) == ["normal", "stopped", "child"])
        #expect(SessionListFilter.default.isDefault)
        #expect(!SessionListFilter.default.includesArchived)
    }

    @Test func aSessionATaskOnlyCameFromIsNotATaskSession() throws {
        let sessions = [try session("origin"), try session("child", parent: "origin")]
        // Where the task was written, and a sub-session that also worked a task (task wins).
        let tasks = [task("t", threads: ["child"], source: "origin")]
        let context = SessionListFilter.Context(tasks: tasks)
        #expect(context.kind(of: sessions[0]) == .normal)
        #expect(context.kind(of: sessions[1]) == .task)
    }

    @Test func eachTypeCanBeShownAlone() throws {
        let sessions = [try session("normal"), try session("child", parent: "normal"), try session("worked")]
        let tasks = [task("t", threads: ["worked"])]
        var filter = SessionListFilter.default
        filter.kinds = [.task]
        #expect(shown(filter, sessions, tasks: tasks) == ["worked"])
        filter.kinds = [.sub]
        #expect(shown(filter, sessions, tasks: tasks) == ["child"])
        filter.kinds = [.normal]
        #expect(shown(filter, sessions, tasks: tasks) == ["normal"])
    }

    @Test func statesSplitActiveInactiveAndArchived() throws {
        let sessions = [try session("on"), try session("off", active: false), try session("old", active: false, archived: true)]
        var filter = SessionListFilter.default
        filter.states = [.active]
        #expect(shown(filter, sessions) == ["on"])
        filter.states = [.inactive]
        #expect(shown(filter, sessions) == ["off"])
        filter.states = [.archived]
        #expect(shown(filter, sessions) == ["old"])
        #expect(filter.includesArchived)
    }

    @Test func attentionKeepsWhatWaitsForYouIsUnreadOrHasOpenTasks() throws {
        let sessions = [
            try session("asks", permissions: 1), try session("unread", active: false, unread: true),
            try session("owes"), try session("finished"), try session("quiet"),
        ]
        let tasks = [task("open", source: "owes"), task("closed", source: "finished", status: "done")]
        var filter = SessionListFilter.default
        filter.attentionOnly = true
        #expect(shown(filter, sessions, tasks: tasks) == ["asks", "unread", "owes"])
    }

    @Test func agentPicksOneAgentOrSessionsWithoutOne() throws {
        let sessions = [try session("m", agent: "mateo"), try session("t", agent: "tomas"), try session("plain")]
        var filter = SessionListFilter.default
        filter.agent = .agent("mateo")
        #expect(shown(filter, sessions) == ["m"])
        filter.agent = .none
        #expect(shown(filter, sessions) == ["plain"])
        filter.agent = .all
        #expect(shown(filter, sessions) == ["m", "t", "plain"])
    }

    @Test func dimensionsCombine() throws {
        let sessions = [
            try session("a", agent: "mateo", permissions: 1), try session("b", active: false, agent: "mateo", unread: true),
            try session("c", agent: "tomas", permissions: 1), try session("d", agent: "mateo"),
        ]
        var filter = SessionListFilter.default
        filter.states = [.active]
        filter.attentionOnly = true
        filter.agent = .agent("mateo")
        #expect(shown(filter, sessions) == ["a"])
        #expect(!filter.isDefault)
    }

    @Test func shortcuts() throws {
        let sessions = [
            try session("normal"), try session("off", active: false), try session("worked"),
            try session("archived", active: false, archived: true, unread: true), try session("asks", permissions: 1),
        ]
        let tasks = [task("t", threads: ["worked"])]
        #expect(shown(.all, sessions, tasks: tasks) == ["normal", "off", "worked", "archived", "asks"])
        #expect(shown(.waitingForMe, sessions, tasks: tasks) == ["worked", "asks"])
        #expect(shown(.activeWithoutTasks, sessions, tasks: tasks) == ["normal", "asks"])
        #expect(SessionListFilter.shortcuts.map(\.filter) == [.all, .waitingForMe, .activeWithoutTasks])
    }

    @Test func survivesARoundTripAndFallsBackToTheDefault() {
        var filter = SessionListFilter.default
        filter.kinds = [.task, .sub]
        filter.states = [.archived]
        filter.attentionOnly = true
        filter.agent = .agent("mateo")
        #expect(SessionListFilter(stored: filter.stored) == filter)
        #expect(SessionListFilter(stored: SessionListFilter.default.stored) == .default)
        filter.agent = .none
        #expect(SessionListFilter(stored: filter.stored) == filter)
        #expect(SessionListFilter(stored: "") == .default)
        #expect(SessionListFilter(stored: "{not json") == .default)
    }

    @Test func describesWhatIsFiltered() {
        let name: (String) -> String? = { $0 == "mateo" ? "Mateo" : nil }
        #expect(SessionListFilter.default.summary(agentName: name) == nil)
        #expect(SessionListFilter.waitingForMe.summary(agentName: name) == "Waiting for me")
        #expect(SessionListFilter.all.summary(agentName: name) == "All sessions")
        var filter = SessionListFilter.default
        filter.kinds = [.task]
        filter.states = [.active]
        filter.agent = .agent("mateo")
        #expect(filter.summary(agentName: name) == "Task sessions · Active · Mateo")
        filter.agent = .none
        filter.attentionOnly = true
        #expect(filter.summary(agentName: name) == "Task sessions · Active · Needs me · No agent")
        filter = .default
        filter.agent = .agent("gone")
        #expect(filter.summary(agentName: name) == "An agent")
    }
}

/// The second line of a session row: who works in it and where, no counters.
@Suite struct SessionRowDetailTests {
    private func session(_ metadata: [String: JSONValue]) throws -> Session {
        try Session(row: ["id": "s", "encryptionMode": "plain", "metadataVersion": 1,
                          "metadata": .string(String(decoding: try JSONValue.object(metadata).encoded(), as: UTF8.self))], keys: nil)
    }

    @Test func agentThenTheFolderItself() throws {
        let agent: JSONValue = ["v": 1, "id": "m", "name": "Mateo", "emoji": "🤖"]
        #expect(try session(["path": "/Users/manny/Projects/manny-agenda", "agentIdentityV1": agent]).listDetail == "Mateo · manny-agenda")
        #expect(try session(["path": "C:\\Users\\manny\\happier\\"]).listDetail == "happier")
        #expect(try session(["host": "mac-mini"]).listDetail == "mac-mini")
        #expect(try session([:]).listDetail == "")
    }
}

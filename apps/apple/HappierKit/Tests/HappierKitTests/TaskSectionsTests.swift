import Foundation
import Testing
@testable import HappierKit

/// Tasks belong to the account; some are linked to sessions. The Tasks panel shows that hierarchy.
@Suite struct TaskSectionsTests {
    static func task(_ id: String, agent: String? = nil, threads: [String] = [], sourceSession: String? = nil,
                     occurrences: [JSONValue] = [], status: String = "todo") -> AgentTask {
        var json: [String: JSONValue] = [
            "v": 1, "id": .string(id), "title": .string(id), "status": .string(status),
            "assignee": agent.map { ["kind": "agent", "agentId": .string($0), "name": .string($0.capitalized)] } ?? ["kind": "user"],
            "threads": .array(threads.map(JSONValue.string)), "log": [], "createdAt": 0, "updatedAt": 0,
        ]
        if let sourceSession { json["source"] = ["kind": "session", "sessionId": .string(sourceSession)] }
        if !occurrences.isEmpty { json["occurrences"] = .array(occurrences) }
        return AgentTask(json: .object(json))!
    }

    @Test func aTaskKnowsEverySessionItIsLinkedToAndWhy() {
        let task = Self.task("t", threads: ["s1", "s2"], sourceSession: "s0",
                             occurrences: [["id": "r1", "startedAt": 1, "sessionId": "s2", "status": "completed"]])
        #expect(task.linkedSessions.map(\.sessionId) == ["s0", "s1", "s2"])
        #expect(task.linkedSessions.first?.reasons == [.source])
        #expect(task.linkedSessions.last?.reasons == [.worked, .occurrence])
        #expect(task.isLinked(to: "s1"))
        #expect(!task.isLinked(to: "s9"))
    }

    @Test func allShowsWhatIsLinkedToTheOpenSessionFirstThenEveryTaskByWhoItIsFor() {
        let tasks = [
            Self.task("mateo-1", agent: "mateo", threads: ["open"]),
            Self.task("mine-1"),
            Self.task("tomas-1", agent: "tomas"),
            Self.task("mine-2", sourceSession: "open"),
        ]
        let sections = AgentTask.sections(tasks, scope: .all, openSessionId: "open", status: .open)
        #expect(sections.map(\.kind) == [.linkedToOpenSession, .assignee(.user), .assignee(.agent(id: "mateo", name: "Mateo", emoji: nil)),
                                         .assignee(.agent(id: "tomas", name: "Tomas", emoji: nil))])
        #expect(sections.first?.tasks.map(\.id) == ["mateo-1", "mine-2"])
        #expect(sections[1].tasks.map(\.id) == ["mine-1", "mine-2"])

        // No open session, or nothing linked to it: just the groups by assignee.
        #expect(AgentTask.sections(tasks, scope: .all, openSessionId: nil, status: .open).first?.kind == .assignee(.user))
        #expect(AgentTask.sections(tasks, scope: .all, openSessionId: "other", status: .open).first?.kind == .assignee(.user))
    }

    @Test func thisSessionShowsOnlyItsLinkedTasks() {
        let tasks = [Self.task("a", threads: ["open"]), Self.task("b"), Self.task("c", agent: "mateo", sourceSession: "open", status: "done")]
        #expect(AgentTask.sections(tasks, scope: .thisSession, openSessionId: "open", status: .all).flatMap(\.tasks).map(\.id) == ["a", "c"])
        #expect(AgentTask.sections(tasks, scope: .thisSession, openSessionId: "open", status: .open).flatMap(\.tasks).map(\.id) == ["a"])
        #expect(AgentTask.sections(tasks, scope: .thisSession, openSessionId: nil, status: .all).isEmpty)
    }

    @MainActor @Test func aRepeatingTaskForASessionRunsOnThatSessionsMachineAndFolder() throws {
        let store = HappierStore(server: URL(string: "http://127.0.0.1:1")!)
        let session = try Session(row: ["id": "s-chat", "seq": 1, "createdAt": 1, "updatedAt": 1, "active": false, "encryptionMode": "plain",
                                        "metadata": .string(#"{"path":"/repo","machineId":"m1","flavor":"codex"}"#), "metadataVersion": 1], keys: nil)
        store.sessions["s-chat"] = session
        var task = Self.task("t")
        task.assignee = .session(id: "s-chat", title: nil)
        #expect(store.recurrenceProblem(for: task) == nil)
        let target = try #require(store.recurrenceTarget(for: task))
        #expect(target.machineId == "m1")
        #expect(target.directory == "/repo")
        #expect(target.providerId == "codex")

        task.assignee = .session(id: "unknown", title: nil)
        #expect(store.recurrenceProblem(for: task) != nil)
    }
}

import Foundation
import Testing
@testable import HappierKit

/// Tasks for the user or their agents (`packages/protocol/src/tasks/agentTask.ts`), sealed in the
/// UserKVStore under `task/<uuid>` with the `agent_task` kind.
@Suite struct AgentTaskTests {
    static let machineKey = Data((0..<32).map { UInt8($0) })
    static let hour = 3_600_000.0

    static func task(_ overrides: [String: JSONValue] = [:]) -> AgentTask {
        var json: [String: JSONValue] = [
            "v": 1, "id": "t1", "title": "Revisar TestFlight", "status": "todo",
            "assignee": ["kind": "agent", "agentId": "a-mateo", "name": "Mateo", "emoji": "🤖"],
            "threads": [], "log": [], "createdAt": 0, "updatedAt": 0,
        ]
        for (key, value) in overrides { json[key] = value }
        return AgentTask(json: .object(json))!
    }

    @Test func sealsUnderItsOwnKindAndKeepsKeysOtherWritersOwn() throws {
        let task = Self.task(["notifiedV1": ["dueSoonAt": 5], "createdBy": ["kind": "user"]])
        let sealed = try task.sealed(machineKey: Self.machineKey)
        #expect(AccountScopedBlob.open(sealed, kind: .agentMemory, machineKey: Self.machineKey) == nil)
        let opened = try #require(AgentTask.open(sealed, machineKey: Self.machineKey))
        #expect(opened.title == "Revisar TestFlight")
        // The CLI daemon's "already told" marks survive an edit made here.
        let edited = opened.applying(AgentTask.Update(title: "Revisar build"), now: 9)
        #expect(edited.json["notifiedV1"] == ["dueSoonAt": 5])
        #expect(edited.json["createdBy"] == ["kind": "user"])
        #expect(AgentTask.kvKey(id: "ABC") == "task/abc")
    }

    @Test func rejectsATaskWithoutTitleOrWithAnUnknownStatus() {
        #expect(AgentTask(json: Self.task().json.merging(["title": " "])) == nil)
        #expect(AgentTask(json: Self.task().json.merging(["status": "later"])) == nil)
    }

    @Test func aListingKeepsTasksWithTheirVersionsAndReportsAFullListing() throws {
        let response: JSONValue = ["items": [
            ["key": "task/t1", "value": .string(try Self.task().sealed(machineKey: Self.machineKey)), "version": 3],
            ["key": "task/gone", "value": "", "version": 1],
            ["key": "task/bad", "value": "bm90IHNlYWxlZA==", "version": 0],
        ]]
        let tasks = AgentTask.records(fromList: response, machineKey: Self.machineKey)
        #expect(tasks.map(\.id) == ["t1"])
        #expect(tasks.first?.version == 3)
    }

    @Test func anUpdateLogsStatusChangesAndCommentsLinksTheThreadOnceAndNullClears() {
        let started = Self.task().applying(AgentTask.Update(status: .inProgress, dueAt: .some(5 * Self.hour), comment: "Empecé", threadSessionId: "s1"), now: 10)
        #expect(started.status == .inProgress)
        #expect(started.dueAt == 5 * Self.hour)
        #expect(started.threads == ["s1"])
        #expect(started.log.count == 1)
        #expect(started.log.first?.text == "Empecé")
        #expect(started.log.first?.status == .inProgress)
        #expect(started.log.first?.byUser == true)
        #expect(started.updatedAt == 10)

        // Same thread linked once; nil clears the date; no status change and no comment, nothing logged.
        let cleared = started.applying(AgentTask.Update(dueAt: .some(nil), threadSessionId: "s1"), now: 11)
        #expect(cleared.threads == ["s1"])
        #expect(cleared.dueAt == nil)
        #expect(cleared.json["dueAt"] == nil)
        #expect(cleared.log.count == 1)
    }

    @Test func anEditBecomesAnUpdateOfOnlyWhatChanged() {
        let original = Self.task(["description": "Antes"])
        var edited = original
        edited.title = "Revisar build"
        edited.status = .blocked
        let update = AgentTask.Update(from: original, to: edited)
        #expect(update.title == "Revisar build")
        #expect(update.status == .blocked)
        #expect(update.description == nil)
        // Applied on top of a newer server copy, the other writer's log entry stays.
        let server = original.applying(AgentTask.Update(comment: "Avance de Mateo"), now: 5)
        let merged = server.applying(update, now: 6)
        #expect(merged.log.map(\.text) == ["Avance de Mateo", nil])
        #expect(merged.title == "Revisar build")
    }

    @Test func filtersByAssigneeAndStatusWithTheSoonestFirst() {
        let now = 100 * Self.hour
        let tasks = [
            Self.task(["id": "done", "status": "done"]),
            Self.task(["id": "late", "dueAt": .number(now - Self.hour)]),
            Self.task(["id": "mine", "assignee": ["kind": "user"], "dueAt": .number(now + Self.hour)]),
            Self.task(["id": "tomas", "assignee": ["kind": "agent", "agentId": "a-tomas"]]),
        ]
        #expect(AgentTask.filter(tasks, assignee: .all, status: .open).map(\.id) == ["late", "mine", "tomas"])
        #expect(AgentTask.filter(tasks, assignee: .me, status: .open).map(\.id) == ["mine"])
        #expect(AgentTask.filter(tasks, assignee: .agent("a-mateo"), status: .all).map(\.id) == ["late", "done"])
        #expect(AgentTask.filter(tasks, assignee: .all, status: .only(.done)).map(\.id) == ["done"])
    }

    @Test func describesTheDueDateLikeTheAgentBoard() {
        let now = 100 * Self.hour
        #expect(Self.task(["dueAt": .number(now - Self.hour)]).due(now: now) == AgentTask.Due(text: "overdue by 1 h", overdue: true))
        #expect(Self.task(["dueAt": .number(now + 30 * Self.hour)]).due(now: now) == AgentTask.Due(text: "due in 30 h", overdue: false))
        #expect(Self.task(["dueAt": .number(now + 3 * 24 * Self.hour)]).due(now: now)?.text == "due in 3 days")
        #expect(Self.task(["dueAt": .number(now + 20 * 60_000)]).due(now: now)?.text == "due in 20 min")
        #expect(Self.task().due(now: now) == nil)
    }

    @Test func theAssignmentMessageCarriesTheTaskContext() {
        let task = Self.task([
            "description": "Wendoline pidió programar X el martes",
            "source": ["kind": "chat", "label": "WhatsApp con Wendoline", "url": "https://wa.me/msg/1"],
            "dueAt": .number(1_794_000_000_000),
        ])
        let utc = TimeZone(identifier: "UTC")!
        let text = task.assignmentMessage(agentName: "Mateo", timeZone: utc)
        #expect(text.contains("Revisar TestFlight"))
        #expect(text.contains("t1"))
        #expect(text.contains("Wendoline pidió programar X el martes"))
        #expect(text.contains("WhatsApp con Wendoline"))
        #expect(text.contains("https://wa.me/msg/1"))
        #expect(text.contains("2026-11-06 21:20"))
        #expect(text.contains("tarea_actualizar"))
    }
}

private extension JSONValue {
    func merging(_ values: [String: JSONValue]) -> JSONValue {
        .object((objectValue ?? [:]).merging(values) { $1 })
    }
}

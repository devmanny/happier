import Foundation
import Testing
@testable import HappierKit

/// Each task's permission mode (YOLO when it has none), archiving, and the Reminders-style quick
/// actions of the list: complete with undo, archive, and what the list shows.
@Suite struct TaskQuickActionsTests {
    static func task(_ overrides: [String: JSONValue] = [:]) -> AgentTask {
        var json: [String: JSONValue] = [
            "v": 1, "id": "t1", "title": "Revisar TestFlight", "status": "todo",
            "assignee": ["kind": "user"], "threads": [], "log": [], "createdAt": 0, "updatedAt": 0,
        ]
        for (key, value) in overrides { json[key] = value }
        return AgentTask(json: .object(json))!
    }

    @Test func aTaskKeepsItsPermissionModeAndIsYoloWithoutOne() {
        #expect(Self.task().permissionMode == .yolo)
        #expect(AgentTask(title: "Nueva").permissionMode == .yolo)
        #expect(Self.task(["permissionMode": "read_only"]).permissionMode == .readOnly)
        #expect(Self.task(["permissionMode": "auto"]).permissionMode == .safeYolo)
        // Stored as the protocol's intent names.
        let asking = Self.task().applying(AgentTask.Update(permissionMode: .default), now: 5)
        #expect(asking.json["permissionMode"]?.stringValue == "default")
        #expect(AgentTask.Update(from: Self.task(), to: asking).permissionMode == .default)
        #expect(Self.task().applying(AgentTask.Update(permissionMode: .safeYolo), now: 5).json["permissionMode"]?.stringValue == "auto")
    }

    @Test func aRewriteKeepsFieldsANewerBuildAddedAtEveryLevel() {
        let newer = Self.task([
            "futureTop": ["x": 1],
            "assignee": ["kind": "agent", "agentId": "a-mateo", "futureAssignee": true],
            "source": ["kind": "chat", "label": "WhatsApp", "futureSource": 2],
            "log": [["at": 1, "by": ["kind": "user"], "text": "hola", "futureLog": "y"], ["at": 2, "by": ["kind": "user"], "status": "someday"]],
        ])
        let json = newer.applying(AgentTask.Update(status: .inProgress, comment: "sigo"), now: 5).json
        #expect(json["futureTop"]?["x"]?.intValue == 1)
        #expect(json["assignee"]?["futureAssignee"]?.boolValue == true)
        #expect(json["source"]?["futureSource"]?.intValue == 2)
        #expect(json["log"]?.arrayValue?.first?["futureLog"]?.stringValue == "y")
        #expect(json["log"]?.arrayValue?[1]["status"]?.stringValue == "someday")
        #expect(json["log"]?.arrayValue?.count == 3)
        // An edited assignee is written as chosen.
        let moved = newer.applying(.assigning(.user), now: 6).json
        #expect(moved["assignee"]?["futureAssignee"] == nil)
    }

    @Test func archivingHidesTheTaskWithoutDeletingItAndPausesItsRepetition() {
        var task = Self.task()
        let archived = task.applying(.archiving(true), now: 7)
        #expect(archived.isArchived && archived.json["archivedAt"]?.doubleValue == 7 && archived.status == .todo)
        #expect(!archived.applying(.archiving(false), now: 8).isArchived)
        task.recurrence = TaskRecurrence(timezone: "UTC", rules: [.init(kind: .weekly([1]), hour: 9, minute: 0)])
        #expect(task.recurrenceToPause(closingWith: .archiving(true))?.paused == true)
    }

    @Test func theListHidesCompletedAndArchivedUnlessAsked() {
        let tasks = [Self.task(["id": "open"]), Self.task(["id": "done", "status": "done"]), Self.task(["id": "gone", "archivedAt": 3])]
        #expect(AgentTask.filter(tasks, assignee: .all, status: .open).map(\.id) == ["open"])
        #expect(AgentTask.filter(tasks, assignee: .all, status: .open, showCompleted: true).map(\.id) == ["open", "done"])
        #expect(AgentTask.filter(tasks, assignee: .all, status: .open, showArchived: true).map(\.id) == ["open", "gone"])
        #expect(AgentTask.filter(tasks, assignee: .all, status: .all).map(\.id) == ["open", "done"])
    }

    @Test func completingFromTheListLingersThreeSecondsAndCanBeUndone() {
        var completions = TaskCompletions()
        let task = Self.task(["status": "in_progress"])
        #expect(completions.complete(task, now: 1_000) == AgentTask.Update(status: .done))
        #expect(completions.isLingering("t1", now: 3_999))
        #expect(!completions.isLingering("t1", now: 4_001))
        // Undoing puts back the status it had.
        #expect(completions.undo("t1") == AgentTask.Update(status: .inProgress))
        #expect(completions.undo("t1") == nil)
        #expect(!completions.isLingering("t1", now: 1_500))
    }

    @Test func aRepeatingTaskIsNotCompletedFromTheList() {
        var task = Self.task()
        #expect(task.completesFromList)
        task.recurrence = TaskRecurrence(timezone: "UTC", rules: [.init(kind: .weekly([1]), hour: 9, minute: 0)])
        #expect(!task.completesFromList)
        var completions = TaskCompletions()
        #expect(completions.complete(task, now: 0) == nil)
        #expect(!Self.task(["status": "done"]).completesFromList)
    }
}

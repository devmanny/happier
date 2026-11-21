import Foundation
import Testing
@testable import HappierKit

/// "My tasks" widget: the user's open tasks, published by the app to the App Group (the widget
/// can't decrypt tasks itself).
@Suite struct TaskWidgetSnapshotTests {
    static let now = Date(timeIntervalSince1970: 1_000_000)
    static let hour = 3_600_000.0

    static func task(_ id: String, status: String = "todo", due: Double? = nil, user: Bool = true, created: Double = 0) -> AgentTask {
        var json: [String: JSONValue] = [
            "v": 1, "id": .string(id), "title": .string("Tarea \(id)"), "status": .string(status),
            "assignee": user ? ["kind": "user"] : ["kind": "agent", "agentId": "a-mateo"],
            "threads": [], "log": [], "createdAt": .number(created), "updatedAt": 0,
        ]
        if let due { json["dueAt"] = .number(due) }
        return AgentTask(json: .object(json))!
    }

    @Test func onlyTheUsersOpenTasksOverdueFirstThenByDueDate() {
        let nowMs = Self.now.timeIntervalSince1970 * 1000
        let tasks = [
            Self.task("later", due: nowMs + 48 * Self.hour),
            Self.task("undated", created: 5),
            Self.task("late", due: nowMs - Self.hour),
            Self.task("soon", status: "in_progress", due: nowMs + Self.hour),
            Self.task("closed", status: "done", due: nowMs - 2 * Self.hour),
            Self.task("agents", due: nowMs - 3 * Self.hour, user: false),
        ]
        let snapshot = TaskWidgetSnapshot(tasks: tasks, limit: 3, now: Self.now)
        #expect(snapshot.total == 4)
        #expect(snapshot.items.map(\.id) == ["late", "soon", "later"])
        #expect(snapshot.overdue == 1)
        #expect(snapshot.items.first?.isOverdue(at: Self.now) == true)
        #expect(snapshot.items[1].status == "In progress")
        #expect(snapshot.items.first?.link == URL(string: "happier-native://task/late"))
    }

    @Test func savesToTheAppGroupAndOnlyCountsAsChangedWhenWhatItShowsChanged() throws {
        let defaults = try #require(UserDefaults(suiteName: "TaskWidgetSnapshotTests"))
        defaults.removePersistentDomain(forName: "TaskWidgetSnapshotTests")
        let snapshot = TaskWidgetSnapshot(tasks: [Self.task("a")], limit: 5, now: Self.now)
        snapshot.save(to: defaults)
        #expect(TaskWidgetSnapshot.load(from: defaults) == snapshot)
        let republished = TaskWidgetSnapshot(tasks: [Self.task("a")], limit: 5, now: Self.now.addingTimeInterval(60))
        #expect(republished.looksLike(TaskWidgetSnapshot.load(from: defaults)))
        #expect(!TaskWidgetSnapshot(tasks: [], limit: 5, now: Self.now).looksLike(snapshot))
    }

    @Test func linksOpenTheTaskOrTheTasksList() throws {
        #expect(AppLink(url: try #require(URL(string: "happier-native://tasks"))) == .tasks)
        #expect(AppLink(url: try #require(URL(string: "happier-native://task/abc-1"))) == .task("abc-1"))
        #expect(AppLink(url: try #require(URL(string: "happier-native://task/"))) == .tasks)
    }
}

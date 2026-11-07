import Foundation

/// The user's open tasks as the "My Tasks" widget shows them: overdue first, then by due date. The
/// app writes it to the App Group it shares with the widget, which can't reach the relay or decrypt
/// tasks itself. Plain text only (no images), to stay well inside the widget's memory budget.
public struct TaskWidgetSnapshot: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        /// The status as the app labels it ("To do", "In progress"…).
        public let status: String
        public let dueAt: Date?
        public let link: URL

        public init(id: String, title: String, status: String, dueAt: Date?, link: URL) {
            self.id = id
            self.title = title
            self.status = status
            self.dueAt = dueAt
            self.link = link
        }

        public func isOverdue(at date: Date) -> Bool { dueAt.map { $0 <= date } ?? false }
    }

    /// Every open task of the user's, including what doesn't fit in `items`.
    public let total: Int
    /// Of those, how many were overdue when published.
    public let overdue: Int
    public let items: [Item]
    public let updatedAt: Date

    private static let key = "happier.tasks.v1"

    /// Opens the Tasks list in the app.
    public static let tasksURL = URL(string: "happier-native://tasks")!

    public static func taskURL(id: String) -> URL {
        URL(string: "happier-native://task/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)")!
    }

    public init(total: Int, overdue: Int, items: [Item], updatedAt: Date) {
        self.total = total
        self.overdue = overdue
        self.items = items
        self.updatedAt = updatedAt
    }

    public init(tasks: [AgentTask], limit: Int, now: Date = .now) {
        let nowMs = now.timeIntervalSince1970 * 1000
        let open = tasks.filter { $0.assignee == .user && $0.status != .done }
        let ordered = open.sorted { a, b in
            let aLate = (a.dueAt ?? .infinity) <= nowMs, bLate = (b.dueAt ?? .infinity) <= nowMs
            if aLate != bLate { return aLate }
            if a.dueAt != b.dueAt { return (a.dueAt ?? .infinity) < (b.dueAt ?? .infinity) }
            return a.createdAt < b.createdAt
        }
        total = ordered.count
        overdue = ordered.filter { ($0.dueAt ?? .infinity) <= nowMs }.count
        items = ordered.prefix(limit).map { task in
            Item(id: task.id, title: task.title, status: task.status.label,
                 dueAt: task.dueAt.map { Date(timeIntervalSince1970: $0 / 1000) }, link: Self.taskURL(id: task.id))
        }
        updatedAt = now
    }

    /// Same content regardless of when it was published: no widget reload needed.
    public func looksLike(_ other: TaskWidgetSnapshot?) -> Bool {
        guard let other else { return false }
        return total == other.total && overdue == other.overdue && items == other.items
    }

    public static func load(from defaults: UserDefaults? = UserDefaults(suiteName: AttentionSnapshot.appGroup)) -> TaskWidgetSnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(TaskWidgetSnapshot.self, from: data)
    }

    public func save(to defaults: UserDefaults? = UserDefaults(suiteName: AttentionSnapshot.appGroup)) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults?.set(data, forKey: Self.key)
    }
}

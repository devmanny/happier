import Foundation

/// The agent card, opened by tapping the composer's status pill: who works in the session and how
/// it's doing, what its other threads are doing now (its shared memory's `now` records), its open
/// tasks, its recent memory, and the session's controls. A session with no agent shows its state,
/// its tasks and its controls instead.
public enum AgentCard {
    /// The colored dot of a row; color is only ever a state.
    public enum State: Equatable, Sendable {
        case online, working, waiting, inactive

        public init(_ status: Session.Status?) {
            switch status {
            case .working: self = .working
            case .permissionRequired, .actionRequired: self = .waiting
            case .idle: self = .online
            case .failed, .offline, nil: self = .inactive
            }
        }
    }

    /// "4 min ago", in the buckets the due dates use.
    public enum Ago: Equatable, Sendable {
        case justNow, minutes(Int), hours(Int), days(Int)

        public init(ms: Double, now: Double) {
            let span = max(0, now - ms)
            let minutes = Int((span / 60_000).rounded(.down))
            if minutes < 1 { self = .justNow } else if minutes < 60 { self = .minutes(minutes) } else if minutes < 48 * 60 {
                self = .hours(minutes / 60)
            } else { self = .days(minutes / (24 * 60)) }
        }

        public var text: String {
            switch self {
            case .justNow: String(localized: "just now")
            case .minutes(let count): String(localized: "\(count) min ago")
            case .hours(let count): String(localized: "\(count) h ago")
            case .days(let count): String(localized: "\(count) days ago")
            }
        }
    }

    /// One thread of the agent: what it says it's doing, where, and since when.
    public struct NowRow: Identifiable, Equatable, Sendable {
        public let sessionId: String
        public let text: String
        /// The thread's title as it reported it, else the session's from the list.
        public let place: String?
        public let ago: Ago
        /// The session the card was opened from: listed first, and not a link (it's already open).
        public let isThisSession: Bool
        public let state: State
        public var id: String { sessionId }
    }

    /// This session's thread first, then the others newest first. A thread with no text is shown as
    /// working, as the memory screen does.
    public static func nowRows(_ memory: AgentMemory?, sessionId: String, now: Double,
                               status: (String) -> Session.Status?, title: (String) -> String?) -> [NowRow] {
        let threads = (memory?.now ?? [])
            .sorted { a, b in
                if (a.sessionId == sessionId) != (b.sessionId == sessionId) { return a.sessionId == sessionId }
                return a.updatedAt > b.updatedAt
            }
        return threads.map { thread in
            NowRow(sessionId: thread.sessionId, text: thread.text,
                   place: thread.title ?? title(thread.sessionId).flatMap { $0.isEmpty ? nil : $0 },
                   ago: Ago(ms: thread.updatedAt, now: now), isThisSession: thread.sessionId == sessionId,
                   state: State(status(thread.sessionId)))
        }
    }

    /// The tasks the card lists, how many are open, and whether "See all" hides some.
    public struct TaskList: Equatable, Sendable {
        public let tasks: [AgentTask]
        public let openCount: Int
        public let hasMore: Bool
    }

    /// As many rows as the mockup draws; "See all its tasks" opens the Tasks list for the rest.
    public static let shownTasks = 3

    /// The agent's open tasks (with no agent, this session's), this session's first and then in the
    /// Tasks list's order (soonest due, then oldest). One just completed with the circle (`lingering`)
    /// stays, struck through, until its time to undo passes, as in the list.
    public static func tasks(_ all: [AgentTask], agentId: String?, sessionId: String, lingering: Set<String>) -> TaskList {
        let mine = all.filter { task in
            guard task.isOpen || lingering.contains(task.id) else { return false }
            if let agentId { return task.assignee.agentId == agentId }
            return task.isLinked(to: sessionId)
        }
        let ordered = AgentTask.filter(mine, assignee: .all, status: .all, showArchived: true)
        let here = ordered.filter { $0.isLinked(to: sessionId) }
        let sorted = here + ordered.filter { !$0.isLinked(to: sessionId) }
        return TaskList(tasks: Array(sorted.prefix(shownTasks)), openCount: mine.filter(\.isOpen).count,
                        hasMore: sorted.count > shownTasks)
    }

    /// The newest journal entries ("See memory" shows the rest).
    public static func recentMemory(_ memory: AgentMemory?) -> [AgentMemory.JournalEntry] {
        Array((memory?.journal ?? []).sorted { $0.at > $1.at }.prefix(3))
    }

    public enum Section: Equatable, Sendable {
        /// No agent: the session's state, model, folder and machine.
        case sessionState
        case now, tasks, memory
        /// The agent's description, collapsed.
        case description
        /// Model and effort, mute notifications.
        case thisSession
        case editAgent
    }

    /// What the card shows, in the mockup's order. An agent whose profile this device doesn't have
    /// (deleted, or not loaded) still has its memory and tasks, but nothing to describe or edit.
    public static func sections(hasAgent: Bool, profileKnown: Bool, hasDescription: Bool) -> [Section] {
        guard hasAgent else { return [.sessionState, .tasks, .thisSession] }
        var sections: [Section] = [.now, .tasks, .memory]
        if profileKnown, hasDescription { sections.append(.description) }
        sections.append(.thisSession)
        if profileKnown { sections.append(.editAgent) }
        return sections
    }

    /// "Opus 5.5 · ~/Projects/Happier · Mac mini", skipping what isn't known.
    public static func sessionLine(model: String?, folder: String?, machine: String?) -> String {
        [model, folder, machine]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

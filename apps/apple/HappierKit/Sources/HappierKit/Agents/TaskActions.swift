import Foundation

extension AgentTask {
    /// Where a task's detail was opened: from inside a session (its tasks, or the panel beside it),
    /// from a list with no session, or from a link (the My Tasks widget, a notification).
    public enum Origin: Hashable, Sendable {
        case session(String)
        case list
        case link

        public var sessionId: String? {
            if case .session(let id) = self { return id }
            return nil
        }
    }

    /// What a task's detail offers, and the current state it shows instead of offering it again.
    public struct Actions: Equatable, Sendable {
        /// "This Session" as somewhere to assign it: only when the task isn't linked to it already.
        public let offersThisSession: Bool
        /// The session it was opened from is where the task is worked (its assignee, a thread, or a
        /// running repeat): "Working in this session".
        public let worksHere: Bool
        /// It is running in the session it was opened from: "Running here".
        public let runsHere: Bool
        /// The session it runs in right now, wherever that is.
        public let runningSessionId: String?
        public let offersStartNow: Bool
        public let offersSchedule: Bool
        /// A start already scheduled: shown with Change and Cancel.
        public let pendingStart: TaskScheduledStart?
        let assignee: Assignee

        /// Whether `candidate` is somewhere else to assign the task (never who it is for already).
        public func offers(_ candidate: Assignee) -> Bool {
            switch (candidate, assignee) {
            case (.user, .user): false
            case (.agent(let a, _, _), .agent(let b, _, _)): a != b
            case (.session(let a, _), .session(let b, _)): a != b
            default: true
            }
        }
    }

    /// The session it runs in: a repeat still running, else the latest session that took it while
    /// it is in progress.
    public var runningSessionId: String? {
        if let running = occurrences.last(where: { $0.status == .running && $0.sessionId != nil }) { return running.sessionId }
        guard status == .inProgress else { return nil }
        return threads.last
    }

    public func availableActions(from origin: Origin) -> Actions {
        let here = origin.sessionId
        let running = isOpen ? runningSessionId : nil
        let worksHere = here.map { id in
            assignee.sessionId == id || threads.contains(id) || occurrences.contains { $0.status == .running && $0.sessionId == id }
        } ?? false
        let canStart = assignee != .user && isOpen && running == nil
        return Actions(
            offersThisSession: here.map { !isLinked(to: $0) } ?? false,
            worksHere: worksHere,
            runsHere: here != nil && running == here,
            runningSessionId: running,
            offersStartNow: canStart,
            offersSchedule: canStart && scheduledStart == nil,
            pendingStart: scheduledStart,
            assignee: assignee)
    }
}

/// The list's circle, as in Reminders: a completed task stays in the list, struck through, for a
/// few seconds before it leaves, and tapping it again in that time puts back the status it had.
/// The completion is written right away; undoing writes the previous status back.
public struct TaskCompletions: Equatable, Sendable {
    public static let lingerMs = 3_000.0

    private var pending: [String: (previous: AgentTask.Status, at: Double)] = [:]

    public init() {}

    /// The update that completes `task` from the list; nil for one the circle doesn't complete.
    public mutating func complete(_ task: AgentTask, now: Double) -> AgentTask.Update? {
        guard task.completesFromList else { return nil }
        pending[task.id] = (task.status, now)
        return AgentTask.Update(status: .done)
    }

    /// The update that undoes a completion made from the list; nil when there is none to undo.
    public mutating func undo(_ id: String) -> AgentTask.Update? {
        pending.removeValue(forKey: id).map { AgentTask.Update(status: $0.previous) }
    }

    /// Completed from the list moments ago: still shown, struck through.
    public func isLingering(_ id: String, now: Double) -> Bool {
        guard let entry = pending[id] else { return false }
        return now - entry.at <= Self.lingerMs
    }

    public var lingeringIds: Set<String> { Set(pending.keys) }

    /// Forgets completions whose time to undo has passed.
    public mutating func expire(now: Double) {
        pending = pending.filter { now - $0.value.at <= Self.lingerMs }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pending.mapValues(\.at) == rhs.pending.mapValues(\.at) && lhs.pending.mapValues(\.previous) == rhs.pending.mapValues(\.previous)
    }
}

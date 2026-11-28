import Foundation

/// Putting running sessions to rest all at once: the rest the idle cleaner gives a session
/// (`sessionRestV1`, `packages/protocol/src/sessionMetadata/sessionRestV1.ts`), so each one shows
/// as Resting and wakes with Wake Session. Only the user's own sessions. The user sees each one
/// with what it's doing and picks which to put to rest, since stopping a busy one interrupts it.
public enum SessionRest {
    /// What a running session is doing, as far as putting it to rest goes.
    public enum Activity: Equatable, Sendable {
        /// Running with nothing in progress (an idle session, or one whose last turn failed).
        case idle
        case working
        /// Waiting for the user to approve something or answer a question.
        case waitingForYou
        /// Messages are queued for it.
        case queued(Int)
        /// This device is still delivering a message to it.
        case sending
        /// Background work it started is still running (`runtimeActivityState`).
        case backgroundWork
        /// A session it started is still running a turn.
        case subSessionWorking
        /// Someone is at its terminal on the computer (`agentState.controlledByUser`).
        case atTerminal

        /// Putting it to rest interrupts something.
        public var isBusy: Bool { self != .idle }
    }

    public struct Candidates: Identifiable, Equatable, Sendable {
        /// Running with nothing in progress.
        public let idle: [String]
        /// Doing something that putting them to rest would interrupt.
        public let busy: [String]

        public init(idle: [String], busy: [String]) {
            self.idle = idle
            self.busy = busy
        }

        public var isEmpty: Bool { idle.isEmpty && busy.isEmpty }
        public var all: [String] { idle + busy }
        public var id: [String] { all }
    }

    /// The running sessions of the user's that can be put to rest (not shared with them, not hidden
    /// system sessions, not ones with no running agent behind them).
    static func running(_ sessions: some Sequence<Session>, now: Date) -> [Session] {
        sessions.filter { $0.active && $0.isUserFacing && $0.sharedAccessLevel == nil && $0.status(at: now) != .offline }
    }

    /// What each running session is doing. `sending` holds the sessions this device is still
    /// delivering a message to. A turn that ended doesn't mean the agent has stopped working:
    /// background work, a sub-session mid-turn or someone at the terminal all keep it busy, as they
    /// keep the idle cleaner away from it.
    public static func activities(_ sessions: some Sequence<Session>, sending: Set<String> = [], now: Date = .now) -> [String: Activity] {
        let running = running(sessions, now: now)
        // A sub-session mid-turn or waiting for the user keeps the session that started it busy.
        let parentsOfWorking = Set(running.filter { [.working, .permissionRequired, .actionRequired].contains($0.status(at: now)) }
            .compactMap(\.parentSessionId))
        var result: [String: Activity] = [:]
        for session in running {
            result[session.id] = switch session.status(at: now) {
            case .permissionRequired, .actionRequired: .waitingForYou
            case .working: .working
            case .idle, .failed, .offline:
                if session.pendingCount > 0 { .queued(session.pendingCount) }
                else if sending.contains(session.id) { .sending }
                else if session.agentState["controlledByUser"]?.boolValue == true { .atTerminal }
                else if parentsOfWorking.contains(session.id) { .subSessionWorking }
                else if session.backgroundActivityCount > 0 { .backgroundWork }
                else { .idle }
            }
        }
        return result
    }

    /// The running sessions that can be put to rest, the most recently used first.
    public static func candidates(_ sessions: some Sequence<Session>, sending: Set<String> = [], now: Date = .now) -> Candidates {
        let activities = activities(sessions, sending: sending, now: now)
        let newestFirst = running(sessions, now: now).sorted { $0.sortDate > $1.sortDate }.map(\.id)
        return Candidates(idle: newestFirst.filter { activities[$0] == .idle },
                          busy: newestFirst.filter { activities[$0]?.isBusy == true })
    }
}

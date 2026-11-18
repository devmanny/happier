import Foundation

/// Putting running sessions to rest all at once: the rest the idle cleaner gives a session
/// (`sessionRestV1`, `packages/protocol/src/sessionMetadata/sessionRestV1.ts`), so each one shows
/// as Resting and wakes with Wake Session. Only the user's own sessions. One that is working, is
/// waiting for the user, or still has messages on their way to it is put to rest only when the
/// user says so, since stopping it interrupts that.
public enum SessionRest {
    public struct Candidates: Identifiable, Equatable, Sendable {
        /// Running with nothing in progress (an idle session, or one whose last turn failed).
        public let idle: [String]
        /// Running a turn, waiting for an approval or an answer, or with messages queued for it.
        public let busy: [String]

        public init(idle: [String], busy: [String]) {
            self.idle = idle
            self.busy = busy
        }

        public var isEmpty: Bool { idle.isEmpty && busy.isEmpty }
        public var all: [String] { idle + busy }
        public var id: [String] { all }
    }

    /// The running sessions that can be put to rest, the most recently used first. `sending` holds
    /// the sessions this device is still delivering a message to. A turn that ended doesn't mean
    /// the agent has stopped working: background work it started (`runtimeActivityState`), a
    /// session it started that is still running a turn, or someone at its terminal on the
    /// computer (`agentState.controlledByUser`) all make it busy, as they keep the idle cleaner
    /// away from it.
    public static func candidates(_ sessions: some Sequence<Session>, sending: Set<String> = [], now: Date = .now) -> Candidates {
        let running = sessions.filter { $0.active && $0.isUserFacing && $0.sharedAccessLevel == nil }
        let working = { (session: Session) in
            switch session.status(at: now) {
            case .working, .permissionRequired, .actionRequired: true
            case .idle, .failed, .offline: false
            }
        }
        let parentsOfWorking = Set(running.filter(working).compactMap(\.parentSessionId))
        var idle: [Session] = [], busy: [Session] = []
        for session in running where session.status(at: now) != .offline {
            let inUse = working(session) || session.pendingCount > 0 || sending.contains(session.id)
                || session.backgroundActivityCount > 0 || parentsOfWorking.contains(session.id)
                || session.agentState["controlledByUser"]?.boolValue == true
            if inUse { busy.append(session) } else { idle.append(session) }
        }
        let newestFirst = { (a: Session, b: Session) in a.sortDate > b.sortDate }
        return Candidates(idle: idle.sorted(by: newestFirst).map(\.id), busy: busy.sorted(by: newestFirst).map(\.id))
    }
}

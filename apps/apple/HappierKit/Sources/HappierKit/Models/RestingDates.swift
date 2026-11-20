import Foundation

/// The date the session list orders a session by: its last activity, held still while the session
/// works. Sessions working at once otherwise overtook each other with every message; one that
/// finishes takes its new place in a single move.
public struct RestingDates: Sendable {
    private var held: [String: Date] = [:]

    public init() {}

    public mutating func date(for session: Session, now: Date) -> Date {
        if session.status(at: now) == .working, let still = held[session.id] { return still }
        held[session.id] = session.sortDate
        return session.sortDate
    }
}

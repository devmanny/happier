import Foundation

/// When auto read goes to sleep by itself: after `limit` in the background with nothing new to
/// read (no message being read or waiting), even while the agent keeps working. In the background
/// the app stays awake only through silent audio and an open socket, so waiting longer costs
/// battery for nothing; the foreground never counts, and coming back to it wakes auto read.
public struct AutoReadIdle: Equatable, Sendable {
    public static let defaultLimit: TimeInterval = 5 * 60

    public struct State: Equatable, Sendable {
        public var reading: Bool
        public var waiting: Int
        public var inBackground: Bool

        public init(reading: Bool, waiting: Int, inBackground: Bool) {
            self.reading = reading
            self.waiting = waiting
            self.inBackground = inBackground
        }

        var isIdle: Bool { inBackground && !reading && waiting == 0 }
    }

    public let limit: TimeInterval
    private var idleSince: TimeInterval?
    /// Asleep: the keep-alive and the background connection are released until the foreground.
    public private(set) var isAsleep = false

    public init(limit: TimeInterval = Self.defaultLimit) {
        self.limit = limit
    }

    /// Records the state at `time` (seconds); idle time counts from the first idle moment.
    public mutating func note(_ state: State, at time: TimeInterval) {
        if !state.inBackground { isAsleep = false }
        if state.isIdle, !isAsleep {
            if idleSince == nil { idleSince = time }
        } else {
            idleSince = nil
        }
    }

    /// When auto read goes to sleep if nothing changes; nil while there is something to read.
    public var deadline: TimeInterval? { idleSince.map { $0 + limit } }

    /// Goes to sleep when the deadline has passed; true if it just did.
    public mutating func sleepIfDue(at time: TimeInterval) -> Bool {
        guard let deadline, time >= deadline else { return false }
        isAsleep = true
        idleSince = nil
        return true
    }
}

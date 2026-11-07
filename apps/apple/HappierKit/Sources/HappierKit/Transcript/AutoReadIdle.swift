import Foundation

/// When auto read stops by itself: after `limit` in the background with nothing to read — no
/// message being read or waiting, and no turn running that will bring one. In the background the
/// app stays awake only through silent audio and an open socket, so waiting longer costs battery
/// for nothing; the foreground never counts.
public struct AutoReadIdle: Equatable, Sendable {
    public static let defaultLimit: TimeInterval = 10 * 60

    public struct State: Equatable, Sendable {
        public var reading: Bool
        public var waiting: Int
        public var turnActive: Bool
        public var inBackground: Bool

        public init(reading: Bool, waiting: Int, turnActive: Bool, inBackground: Bool) {
            self.reading = reading
            self.waiting = waiting
            self.turnActive = turnActive
            self.inBackground = inBackground
        }

        var isIdle: Bool { inBackground && !reading && waiting == 0 && !turnActive }
    }

    public let limit: TimeInterval
    private var idleSince: TimeInterval?

    public init(limit: TimeInterval = Self.defaultLimit) {
        self.limit = limit
    }

    /// Records the state at `time` (seconds); idle time counts from the first idle moment.
    public mutating func note(_ state: State, at time: TimeInterval) {
        if state.isIdle {
            if idleSince == nil { idleSince = time }
        } else {
            idleSince = nil
        }
    }

    /// When auto read stops if nothing changes; nil while there is something to read or coming.
    public var deadline: TimeInterval? { idleSince.map { $0 + limit } }

    public func shouldPause(at time: TimeInterval) -> Bool {
        deadline.map { time >= $0 } ?? false
    }
}

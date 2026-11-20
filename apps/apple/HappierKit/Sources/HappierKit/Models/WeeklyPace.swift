import Foundation

/// Whether a weekly limit lasts until it resets at the pace it's being used: every weekly ring and
/// bar (the conversation's header, the agents atop the list, an agent's card) reads its state here.
public struct WeeklyPace: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// At this pace it lasts until the reset.
        case onTrack
        /// At this pace it runs out before the reset.
        case runsOutEarly
        /// Used up, or (running out early) gone within a day.
        case critical
    }

    public static let week: TimeInterval = 7 * 24 * 60 * 60
    private static let day: TimeInterval = 24 * 60 * 60

    /// How much is used, 0…1.
    public let used: Double
    /// How much of the window has gone by, 0…1: where "today" sits on the ring or bar.
    public let elapsed: Double
    /// Use against the time gone by, with a one-day floor: above 1 it runs out before the reset.
    public let pace: Double
    /// When it runs out at this pace; nil while nothing is used.
    public let runsOutAt: Date?
    public let resetsAt: Date
    public let state: State

    /// Used faster than the week allows: the case "Runs out…" and the "today" mark show.
    public var isOverPace: Bool { pace > 1 }

    public init(used: Double, resetsAt: Date, duration: TimeInterval = WeeklyPace.week, now: Date) {
        let duration = duration > 0 ? duration : Self.week
        let used = min(max(used, 0), 1)
        let gone = min(max(now.timeIntervalSince(resetsAt.addingTimeInterval(-duration)), 0), duration)
        let elapsed = gone / duration
        // A one-day floor, so a little use in the first hours doesn't read as racing ahead.
        let pace = used / max(elapsed, 1.0 / 7)
        let runsOutAt: Date?
        if used >= 1 {
            runsOutAt = now
        } else if used > 0, gone > 0 {
            runsOutAt = now.addingTimeInterval((1 - used) / (used / gone))
        } else {
            runsOutAt = nil
        }
        self.used = used
        self.elapsed = elapsed
        self.pace = pace
        self.runsOutAt = runsOutAt
        self.resetsAt = resetsAt
        if used >= 1 || (pace > 1 && runsOutAt.map { $0.timeIntervalSince(now) < Self.day } == true) {
            state = .critical
        } else if pace > 1 {
            state = .runsOutEarly
        } else {
            state = .onTrack
        }
    }

    /// The pace of a weekly meter; nil when the provider gave no reset time to measure the week from.
    public init?(meter: ProviderUsage.Meter, now: Date) {
        guard let resetsAt = meter.resetsAt else { return nil }
        self.init(used: meter.usedPercent / 100, resetsAt: resetsAt, duration: meter.windowDuration ?? Self.week, now: now)
    }

    /// "Runs out Saturday", "Runs out in 1 h 30 min" or "Used up"; nil while it lasts the week.
    public func runsOutLabel(now: Date, calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String? {
        guard state != .onTrack else { return nil }
        guard used < 1, let runsOutAt else { return String(localized: "Used up") }
        let left = runsOutAt.timeIntervalSince(now)
        if left >= Self.day {
            let style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            return String(localized: "Runs out \(runsOutAt.formatted(style.weekday(.wide)))")
        }
        return String(localized: "Runs out in \(Self.duration(left))")
    }

    /// "1 h 30 min", "2 h", "40 min": to the nearest ten minutes, at least ten.
    static func duration(_ interval: TimeInterval) -> String {
        let minutes = max(10, Int((interval / 600).rounded()) * 10)
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return String(localized: "\(rest) min") }
        return rest == 0 ? String(localized: "\(hours) h") : String(localized: "\(hours) h \(rest) min")
    }
}

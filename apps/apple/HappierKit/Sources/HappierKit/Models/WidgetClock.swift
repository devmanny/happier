import Foundation

/// How widgets show time: whole minutes ("4m", "1h 12m"), redrawn every 30 seconds by their
/// timeline, never a clock ticking seconds (SwiftUI's `.timer` and `.relative` text styles).
public enum WidgetClock {
    /// Seconds between redraws.
    public static let step: TimeInterval = 30
    /// How far ahead a timeline is drawn before it reloads.
    public static let span: TimeInterval = 30 * 60

    /// When a timeline redraws: now, then every `step` until `end` (`span` from now by default).
    public static func dates(from start: Date, until end: Date? = nil) -> [Date] {
        let end = end ?? start.addingTimeInterval(span)
        return Array(stride(from: 0, through: max(0, end.timeIntervalSince(start)), by: step).map(start.addingTimeInterval))
    }

    /// The time between two moments, either way round, in whole minutes, hours and days (at most
    /// two units): "0m", "4m", "1h 12m", "2d 3h".
    public static func elapsed(from: Date, to: Date, locale: Locale = .current) -> String {
        let minutes = Int64(abs(to.timeIntervalSince(from)) / 60)
        return Duration.seconds(minutes * 60).formatted(
            .units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2,
                   zeroValueUnits: .hide, fractionalPart: .hide)
            .locale(locale))
    }
}

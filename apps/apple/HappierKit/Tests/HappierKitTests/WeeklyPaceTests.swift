import Foundation
import Testing
@testable import HappierKit

/// The weekly limit's pace: white while it lasts the week, early when it runs out before the reset,
/// critical when used up or gone within a day.
@Suite struct WeeklyPaceTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    private let locale = Locale(identifier: "en_US")
    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 24 * 3600

    /// Thursday 5 Nov 2026, 12:00 UTC.
    private var thursdayNoon: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 12))! }

    /// A reading `daysIn` into its week (`resetsAt` = the week's start + 7 days), at `thursdayNoon`.
    private func pace(used: Double, daysIn: Double) -> WeeklyPace {
        WeeklyPace(used: used, resetsAt: thursdayNoon.addingTimeInterval(WeeklyPace.week - daysIn * day), now: thursdayNoon)
    }

    private func label(_ pace: WeeklyPace) -> String? { pace.runsOutLabel(now: thursdayNoon, calendar: calendar, locale: locale) }

    @Test func dayOneWithATenthUsedLastsTheWeek() {
        let p = pace(used: 0.10, daysIn: 1)
        #expect(p.state == .onTrack)
        #expect(label(p) == nil)
        #expect(abs(p.elapsed - 1.0 / 7) < 1e-9)
    }

    @Test func daySixWithEightyPercentLastsTheWeek() {
        #expect(pace(used: 0.80, daysIn: 6).state == .onTrack)
    }

    @Test func dayTwoWithHalfUsedRunsOutOnSaturday() {
        let p = pace(used: 0.50, daysIn: 2)
        #expect(p.state == .runsOutEarly)
        #expect(p.pace == 0.5 / (2.0 / 7))
        #expect(p.runsOutAt == thursdayNoon.addingTimeInterval(2 * day))
        #expect(p.isOverPace)
        #expect(!pace(used: 0.80, daysIn: 6).isOverPace)
        #expect(label(p) == "Runs out Saturday")
    }

    @Test func daySixWithNinetyNinePercentRunsOutWithinTheDay() {
        let p = pace(used: 0.99, daysIn: 6)
        #expect(p.state == .critical)
        // 0.01 left at 0.99 per 6 days: 87 minutes, shown to the nearest 10.
        #expect(label(p) == "Runs out in 1 h 30 min")
    }

    @Test func aSmallReadingInTheFirstHoursStaysWhite() {
        // At this rate it would run out in 38 h, but the one-day floor keeps the pace at 0.35.
        let p = WeeklyPace(used: 0.05, resetsAt: thursdayNoon.addingTimeInterval(WeeklyPace.week - 2 * hour), now: thursdayNoon)
        #expect(p.state == .onTrack)
        // Even within a day of running out, an early reading under the floor isn't critical.
        let quick = WeeklyPace(used: 0.10, resetsAt: thursdayNoon.addingTimeInterval(WeeklyPace.week - 2 * hour), now: thursdayNoon)
        #expect(quick.runsOutAt.map { $0.timeIntervalSince(thursdayNoon) < day } == true)
        #expect(quick.state == .onTrack)
    }

    @Test func thirtyPercentOnDayOneRunsOutEarly() {
        let p = pace(used: 0.30, daysIn: 1)
        #expect(p.state == .runsOutEarly)
        #expect(label(p)?.hasPrefix("Runs out ") == true)
    }

    @Test func usedUpIsCritical() {
        let p = pace(used: 1, daysIn: 3)
        #expect(p.state == .critical)
        #expect(p.runsOutAt == thursdayNoon)
        #expect(label(p) == "Used up")
    }

    @Test func aMeterWithoutAResetHasNoPace() throws {
        let usage = try #require(ProviderUsage(snapshot: ["meters": [
            ["meterId": "seven_day", "utilizationPct": 50, "windowDurationMs": 604_800_000, "status": "ok"],
            ["meterId": "weekly", "utilizationPct": 50, "windowDurationMs": 604_800_000, "resetsAt": .number(thursdayNoon.timeIntervalSince1970 * 1000 + 5 * day * 1000), "status": "ok"],
        ]]))
        #expect(WeeklyPace(meter: usage.meters[0], now: thursdayNoon) == nil)
        #expect(WeeklyPace(meter: usage.meters[1], now: thursdayNoon)?.state == .runsOutEarly)
    }
}

import Foundation
import Testing
@testable import HappierKit

/// Widgets show how long ago or how long for in whole minutes, redrawn every 30 seconds: never a
/// clock ticking seconds.
struct WidgetClockTests {
    private let en = Locale(identifier: "en_US")
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func timesAreWholeMinutesNeverSeconds() {
        #expect(WidgetClock.elapsed(from: start, to: start.addingTimeInterval(59), locale: en) == "0m")
        #expect(WidgetClock.elapsed(from: start, to: start.addingTimeInterval(4 * 60 + 59), locale: en) == "4m")
        #expect(WidgetClock.elapsed(from: start, to: start.addingTimeInterval(72 * 60 + 30), locale: en) == "1h 12m")
        #expect(WidgetClock.elapsed(from: start, to: start.addingTimeInterval(51 * 3600 + 7 * 60), locale: en) == "2d 3h")
        // A time still ahead reads the same way ("Resets in …").
        #expect(WidgetClock.elapsed(from: start.addingTimeInterval(125 * 60), to: start, locale: en) == "2h 5m")
    }

    @Test func aTimelineRedrawsEveryThirtySecondsUntilItsNextReload() {
        let dates = WidgetClock.dates(from: start, until: start.addingTimeInterval(5 * 60))
        #expect(dates.first == start)
        #expect(dates.count == 11)
        #expect(zip(dates, dates.dropFirst()).allSatisfy { $1.timeIntervalSince($0) == 30 })
        #expect(WidgetClock.dates(from: start).last == start.addingTimeInterval(30 * 60))
    }
}

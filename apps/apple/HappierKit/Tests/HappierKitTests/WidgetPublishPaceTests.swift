import Testing
@testable import HappierKit

/// Widgets and the watch are refreshed at most once a minute (WidgetKit budgets reloads, and each
/// one wakes the widget extension and the watch radio), after a burst has settled.
@Suite struct WidgetPublishPaceTests {
    @Test func waitsForTheBurstToSettleAndAtLeastAMinuteSinceTheLastPublish() {
        #expect(WidgetPublishPace.wait(lastPublishedAt: nil, now: 100) == 5)
        #expect(WidgetPublishPace.wait(lastPublishedAt: 90, now: 100) == 50)
        #expect(WidgetPublishPace.wait(lastPublishedAt: 0, now: 100) == 5)
    }
}

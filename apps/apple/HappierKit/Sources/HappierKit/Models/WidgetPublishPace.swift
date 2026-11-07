import Foundation

/// How long the widget/watch publisher waits after a change before publishing: a few seconds for
/// a burst of updates to settle, and never sooner than a minute after the last publish (streaming
/// agents change the excerpts constantly; each reload wakes the widget extension and the watch).
public enum WidgetPublishPace {
    public static let settle: TimeInterval = 5
    public static let minimumInterval: TimeInterval = 60

    public static func wait(lastPublishedAt: TimeInterval?, now: TimeInterval) -> TimeInterval {
        guard let last = lastPublishedAt else { return settle }
        return max(settle, minimumInterval - (now - last))
    }
}

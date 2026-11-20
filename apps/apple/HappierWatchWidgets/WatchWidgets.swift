import HappierKit
import SwiftUI
import WidgetKit

/// The watch's complications and Smart Stack cards, from the summary the watch app saves in the
/// App Group whenever the iPhone sends a new one.
@main
struct HappierWatchWidgets: WidgetBundle {
    var body: some Widget {
        NeedsYouWidget()
        WorkingWidget()
        UsageWidget()
    }
}

struct WatchEntry: TimelineEntry {
    let date: Date
    let context: WatchContext?
}

struct WatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchEntry { WatchEntry(date: .now, context: .preview) }

    func getSnapshot(in context: Context, completion: @escaping (WatchEntry) -> Void) {
        completion(WatchEntry(date: .now, context: context.isPreview ? .preview : WatchContext.load() ?? .preview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchEntry>) -> Void) {
        // The app reloads these whenever the iPhone sends something new; this only re-reads now and then.
        completion(Timeline(entries: [WatchEntry(date: .now, context: WatchContext.load())], policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

private func sessionURL(_ item: AttentionSnapshot.Item?) -> URL? {
    item.flatMap { URL(string: "happier-watch://session/\($0.sessionId)") }
}

// MARK: - Needs You

/// How many sessions wait on you; the first one by name.
struct NeedsYouWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "happier.watch.attention", provider: WatchProvider()) { entry in
            NeedsYouView(entry: entry)
        }
        .configurationDisplayName("Needs You")
        .description("Sessions waiting for your approval or with replies you haven't read.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

private struct NeedsYouView: View {
    let entry: WatchEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: AttentionSnapshot? { entry.context?.attention }
    private var total: Int { snapshot?.total ?? 0 }
    private var first: AttentionSnapshot.Item? { snapshot?.items.first }
    private var waiting: Bool { first?.reason == .waitingForYou }

    var body: some View {
        content
            .widgetURL(sessionURL(first))
            .containerBackground(for: .widget) { Color.clear }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryInline:
            Text(total == 0 ? "Happier · all caught up" : "Happier · \(total) need you")
        case .accessoryCorner:
            Text("\(total)")
                .font(.title3.weight(.bold).monospacedDigit())
                .widgetCurvesContent()
                .widgetLabel { Text(total == 0 ? "Caught up" : waiting ? "Waiting" : "Unread") }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image("Logo").resizable().scaledToFit().frame(width: 12, height: 12)
                    Text(total == 0 ? "All caught up" : "\(total) need you").font(.headline).widgetAccentable()
                }
                if let first {
                    Text(first.title).font(.caption).lineLimit(1)
                    Text(first.request?.summary ?? (waiting ? "Waiting for you" : "New reply")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: -1) {
                    Image(systemName: waiting ? "hand.raised.fill" : "bubble.left.fill").font(.caption)
                    Text("\(total)").font(.title3.weight(.bold).monospacedDigit())
                }
                .widgetAccentable()
            }
        }
    }
}

// MARK: - Working

/// The agents working now, with how long the first has been at it.
struct WorkingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "happier.watch.working", provider: WatchProvider()) { entry in
            WorkingView(entry: entry)
        }
        .configurationDisplayName("Working Now")
        .description("The agents working right now and how long they've been at it.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

private struct WorkingView: View {
    let entry: WatchEntry
    @Environment(\.widgetFamily) private var family
    private var working: [ActivitySnapshot.Item] { entry.context?.activity.working ?? [] }

    var body: some View {
        content.containerBackground(for: .widget) { Color.clear }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryInline:
            if let first = working.first {
                Text("\(working.count) working · \(first.since, style: .timer)")
            } else {
                Text("No agents working")
            }
        case .accessoryCorner:
            Text("\(working.count)")
                .font(.title3.weight(.bold).monospacedDigit())
                .widgetCurvesContent()
                .widgetLabel {
                    if let first = working.first { Text(first.since, style: .timer) } else { Text("Idle") }
                }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill").font(.caption2)
                    Text(working.isEmpty ? "No agents working" : "\(working.count) working").font(.headline).widgetAccentable()
                }
                ForEach(working.prefix(2)) { item in
                    HStack(spacing: 4) {
                        Text(item.title).font(.caption).lineLimit(1)
                        Spacer(minLength: 2)
                        Text(item.since, style: .timer).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: -1) {
                    Image(systemName: "bolt.fill").font(.caption)
                    Text("\(working.count)").font(.title3.weight(.bold).monospacedDigit())
                }
                .widgetAccentable()
            }
        }
    }
}

// MARK: - Usage

/// A ring of the tightest provider limit, as last read by the app.
struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "happier.watch.usage", provider: WatchProvider()) { entry in
            UsageView(entry: entry)
        }
        .configurationDisplayName("Usage")
        .description("How close you are to each provider's limits.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryCorner])
    }
}

private struct UsageView: View {
    let entry: WatchEntry
    @Environment(\.widgetFamily) private var family
    private var usage: [ActivitySnapshot.Usage] { entry.context?.activity.usage ?? [] }

    private static let names = ["claude": "Claude", "codex": "Codex", "anthropic": "Claude", "openai": "Codex"]
    private func tint(_ used: Double) -> Color { used >= 90 ? .red : used >= 70 ? .orange : .green }

    var body: some View {
        content.containerBackground(for: .widget) { Color.clear }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                if usage.isEmpty {
                    Text("Usage").font(.headline)
                    Text("Open a session in Happier to read its limits.").font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(usage.prefix(2)) { item in
                    HStack(spacing: 6) {
                        Text(Self.names[item.providerId] ?? item.providerId).font(.caption.weight(.semibold))
                        Gauge(value: item.usedPercent, in: 0...100) { EmptyView() }
                            .gaugeStyle(.accessoryLinearCapacity)
                            .tint(tint(item.usedPercent))
                        Text("\(Int(item.usedPercent))%").font(.caption2.monospacedDigit())
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryCorner:
            if let first = usage.first {
                Text("\(Int(first.usedPercent))%")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .widgetCurvesContent()
                    .widgetLabel {
                        Gauge(value: first.usedPercent, in: 0...100) { Text(Self.names[first.providerId] ?? first.providerId) }
                            .tint(tint(first.usedPercent))
                    }
            } else {
                Image(systemName: "gauge.with.dots.needle.0percent").widgetLabel { Text("Usage") }
            }
        default:
            if let first = usage.first {
                Gauge(value: first.usedPercent, in: 0...100) {
                    Text(Self.names[first.providerId] ?? first.providerId)
                } currentValueLabel: {
                    Text("\(Int(first.usedPercent))")
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(tint(first.usedPercent))
            } else {
                ZStack { AccessoryWidgetBackground(); Image(systemName: "gauge.with.dots.needle.0percent") }
            }
        }
    }
}

extension WatchContext {
    /// What the complication gallery shows before the iPhone has sent anything.
    static var preview: WatchContext {
        let now = Date.now
        let attention = AttentionSnapshot(total: 2, items: [
            .init(sessionId: "a", title: "Deploy the release", agentId: "claude", reason: .waitingForYou, date: now.addingTimeInterval(-120), link: nil,
                  request: .init(id: "r", tool: "Bash", summary: "Bash: git push origin main"), lastAgentText: "Ready to push the tag."),
            .init(sessionId: "b", title: "Fix the flaky test", agentId: "codex", reason: .unread, date: now.addingTimeInterval(-900), link: nil,
                  lastAgentText: "All tests pass now."),
        ], updatedAt: now)
        let activity = ActivitySnapshot(working: [
            .init(sessionId: "c", title: "Write the changelog", agentId: "claude", folder: "happier", state: .working, since: now.addingTimeInterval(-245), link: nil),
        ], recent: [], usage: [
            .init(providerId: "claude", plan: "Max", meter: "weekly", usedPercent: 64, resetsAt: now.addingTimeInterval(86_400), fetchedAt: now),
            .init(providerId: "codex", plan: "Pro", meter: "five_hour", usedPercent: 28, resetsAt: now.addingTimeInterval(7_200), fetchedAt: now),
        ], updatedAt: now)
        return WatchContext(attention: attention, activity: activity)
    }
}

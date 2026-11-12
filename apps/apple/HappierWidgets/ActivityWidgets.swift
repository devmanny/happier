import HappierKit
import SwiftUI
import WidgetKit
#if os(iOS)
import AppIntents
#endif

// MARK: - Shared timeline

struct ActivityEntry: TimelineEntry {
    let date: Date
    let snapshot: ActivitySnapshot?
}

struct ActivityProvider: TimelineProvider {
    func placeholder(in context: Context) -> ActivityEntry { ActivityEntry(date: .now, snapshot: .preview) }

    func getSnapshot(in context: Context, completion: @escaping (ActivityEntry) -> Void) {
        completion(ActivityEntry(date: .now, snapshot: context.isPreview ? .preview : ActivitySnapshot.load() ?? .preview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ActivityEntry>) -> Void) {
        // The app reloads the widgets when anything shown changes; this only re-reads now and then.
        completion(Timeline(entries: [ActivityEntry(date: .now, snapshot: ActivitySnapshot.load())],
                            policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

private let newSessionURL = URL(string: "happier-native://new")!

private extension ActivitySnapshot.State {
    var label: LocalizedStringKey {
        switch self {
        case .working: "Working"
        case .waiting: "Waiting for you"
        case .unread: "New reply"
        case .failed: "Failed"
        case .idle: "Idle"
        case .offline: "Stopped"
        }
    }

    var color: Color {
        switch self {
        case .working: .blue
        case .waiting: .orange
        case .unread: .blue
        case .failed: .red
        case .idle: .secondary
        case .offline: .gray
        }
    }

    var symbol: String {
        switch self {
        case .working: "bolt.fill"
        case .waiting: "hand.raised.fill"
        case .unread: "circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .idle: "moon.fill"
        case .offline: "stop.circle"
        }
    }
}

/// A stopped session the idle cleaner put to rest shows resting, quietly; one the user stopped shows
/// stopped.
private extension ActivitySnapshot.Item {
    var label: LocalizedStringKey { isResting ? "Resting" : state.label }
    var color: Color { isResting ? .secondary : state.color }
    var symbol: String { isResting ? "moon.zzz" : state.symbol }
}

/// The small Happier mark with a title, at the top of a widget.
private struct WidgetHeader: View {
    let title: LocalizedStringKey
    var body: some View {
        HStack(spacing: 5) {
            Image("Logo").resizable().scaledToFit().frame(width: 15, height: 15)
            Text(title).font(.caption.weight(.semibold))
        }
    }
}

private func washed(_ color: Color) -> some View {
    LinearGradient(colors: [color.opacity(0.2), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
        .background(.background)
}

// MARK: - Working Now

/// The agents working right now, with how long each has been at it.
struct WorkingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "happier.working", provider: ActivityProvider()) { entry in
            WorkingView(entry: entry)
        }
        .configurationDisplayName("Working Now")
        .description("The agents working right now and how long they've been at it.")
        #if os(iOS)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular])
        #else
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        #endif
    }
}

private struct WorkingView: View {
    let entry: ActivityEntry
    @Environment(\.widgetFamily) private var family
    private var working: [ActivitySnapshot.Item] { entry.snapshot?.working ?? [] }

    var body: some View {
        content
            .widgetURL(working.first?.link)
            .containerBackground(for: .widget) { washed(.blue) }
    }

    @ViewBuilder private var content: some View {
        switch family {
        #if os(iOS)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: -1) {
                    Image(systemName: "bolt.fill").font(.caption)
                    Text("\(working.count)").font(.title3.weight(.bold).monospacedDigit())
                }
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(working.isEmpty ? "No agents working" : "\(working.count) working").font(.headline)
                if let first = working.first {
                    Text(first.title).font(.caption).lineLimit(1)
                    Text(first.since, style: .timer).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        #endif
        case .systemSmall:
            VStack(alignment: .leading, spacing: 2) {
                WidgetHeader(title: "Working")
                Spacer(minLength: 0)
                Text("\(working.count)")
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                    .widgetAccentable()
                Text(working.isEmpty ? "No agents working" : working.count == 1 ? "agent working" : "agents working")
                    .font(.caption).foregroundStyle(.secondary)
                if let first = working.first {
                    HStack(spacing: 4) {
                        Text(first.title).lineLimit(1)
                        Spacer(minLength: 2)
                        Text(first.since, style: .timer).monospacedDigit().multilineTextAlignment(.trailing)
                    }
                    .font(.caption2.weight(.medium))
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    WidgetHeader(title: "Working Now")
                    Spacer()
                    Text("\(working.count)").font(.headline.monospacedDigit()).widgetAccentable()
                }
                if working.isEmpty {
                    Spacer(minLength: 0)
                    Label("No agents working right now", systemImage: "moon.zzz.fill")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(working.prefix(family == .systemLarge ? 7 : 3)) { item in
                        Link(destination: item.link ?? newSessionURL) {
                            HStack(spacing: 8) {
                                AgentBadge(agentId: item.agentId, size: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    if let folder = item.folder {
                                        Text(folder).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 4)
                                Text(item.since, style: .timer)
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 64, alignment: .trailing)
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Recent

/// The latest conversations and where each one stands; tap one to open it.
struct RecentWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "happier.recent", provider: ActivityProvider()) { entry in
            RecentView(entry: entry)
        }
        .configurationDisplayName("Recent Sessions")
        .description("Your latest conversations and what each one is doing.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private struct RecentView: View {
    let entry: ActivityEntry
    @Environment(\.widgetFamily) private var family
    private var recent: [ActivitySnapshot.Item] { entry.snapshot?.recent ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                WidgetHeader(title: "Recent")
                Spacer()
                Link(destination: newSessionURL) {
                    Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(.blue)
                }
            }
            if recent.isEmpty {
                Spacer(minLength: 0)
                Text("Open Happier to see your sessions.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            } else {
                ForEach(recent.prefix(family == .systemLarge ? 8 : 3)) { item in
                    Link(destination: item.link ?? newSessionURL) {
                        HStack(spacing: 8) {
                            AgentBadge(agentId: item.agentId, size: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                HStack(spacing: 4) {
                                    Image(systemName: item.symbol).font(.system(size: 8)).foregroundStyle(item.color)
                                        .accessibilityHidden(true)
                                    Text(item.label)
                                    Text("·")
                                    if item.state == .working {
                                        Text(item.since, style: .timer).monospacedDigit()
                                    } else {
                                        Text(item.since, style: .relative)
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .containerBackground(for: .widget) { washed(.indigo) }
    }
}

// MARK: - Usage

/// How much of each provider's tightest limit is used, as of the last time the app read it.
struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "happier.usage", provider: ActivityProvider()) { entry in
            UsageView(entry: entry)
        }
        .configurationDisplayName("Usage")
        .description("How close you are to each provider's limits.")
        #if os(iOS)
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular])
        #else
        .supportedFamilies([.systemSmall, .systemMedium])
        #endif
    }
}

private struct UsageView: View {
    let entry: ActivityEntry
    @Environment(\.widgetFamily) private var family
    private var usage: [ActivitySnapshot.Usage] { entry.snapshot?.usage ?? [] }

    private static let names = ["claude": "Claude", "codex": "Codex", "anthropic": "Claude", "openai": "Codex"]

    private func tint(_ used: Double) -> Color { used >= 90 ? .red : used >= 70 ? .orange : .green }

    var body: some View {
        content.containerBackground(for: .widget) { washed(.green) }
    }

    @ViewBuilder private var content: some View {
        switch family {
        #if os(iOS)
        case .accessoryCircular:
            if let first = usage.first {
                Gauge(value: first.usedPercent, in: 0...100) {
                    Text(Self.names[first.providerId] ?? first.providerId)
                } currentValueLabel: {
                    Text("\(Int(first.usedPercent))")
                }
                .gaugeStyle(.accessoryCircularCapacity)
            } else {
                ZStack { AccessoryWidgetBackground(); Image(systemName: "gauge.with.dots.needle.0percent") }
            }
        #endif
        default:
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "Usage")
                if usage.isEmpty {
                    Spacer(minLength: 0)
                    Text("Open a session in Happier to read its limits.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if family == .systemSmall {
                    Spacer(minLength: 0)
                    HStack(spacing: 10) {
                        ForEach(usage.prefix(2)) { item in
                            VStack(spacing: 4) {
                                Gauge(value: item.usedPercent, in: 0...100) {
                                    EmptyView()
                                } currentValueLabel: {
                                    Text("\(Int(item.usedPercent))%").font(.caption2.weight(.bold))
                                }
                                .gaugeStyle(.accessoryCircularCapacity)
                                .tint(tint(item.usedPercent))
                                Text(Self.names[item.providerId] ?? item.providerId).font(.caption2.weight(.semibold))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    Text("used of the tightest limit").font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(usage.prefix(3)) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                AgentBadge(agentId: item.providerId, size: 18)
                                Text(Self.names[item.providerId] ?? item.providerId).font(.subheadline.weight(.semibold))
                                Text(item.meter.replacingOccurrences(of: "_", with: " ")).font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int(item.usedPercent))% used").font(.subheadline.weight(.bold).monospacedDigit())
                            }
                            ProgressView(value: item.usedPercent, total: 100).tint(tint(item.usedPercent))
                            HStack(spacing: 4) {
                                if let reset = item.resetsAt { Text("Resets in \(reset, style: .relative)") }
                                if let fetched = item.fetchedAt {
                                    Spacer(minLength: 4)
                                    Text("Read \(fetched, style: .relative) ago")
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - New Session

/// One tap to the empty chat for a new session (Home Screen and Lock Screen).
struct NewSessionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "happier.new-session", provider: ActivityProvider()) { _ in
            NewSessionView()
        }
        .configurationDisplayName("New Session")
        .description("Start a new session in one tap.")
        #if os(iOS)
        .supportedFamilies([.systemSmall, .accessoryCircular])
        #else
        .supportedFamilies([.systemSmall])
        #endif
    }
}

private struct NewSessionView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            #if os(iOS)
            if family == .accessoryCircular {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "plus.bubble.fill").font(.title3)
                }
            } else {
                card
            }
            #else
            card
            #endif
        }
        .widgetURL(newSessionURL)
        .containerBackground(for: .widget) { washed(.blue) }
    }

    private var card: some View {
        VStack(alignment: .leading) {
            WidgetHeader(title: "Happier")
            Spacer()
            Image(systemName: "plus.bubble.fill").font(.system(size: 34)).foregroundStyle(.blue).widgetAccentable()
            Text("New Session").font(.headline)
            Text("What should we work on?").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

#if os(iOS)
/// The same in Control Center and on the Lock Screen's control buttons.
struct NewSessionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "happier.control.new-session") {
            ControlWidgetButton(action: OpenURLIntent(newSessionURL)) {
                Label("New Session", systemImage: "plus.bubble.fill")
            }
        }
        .displayName("New Happier Session")
        .description("Opens Happier on a new session.")
    }
}
#endif

extension ActivitySnapshot {
    /// What the widget gallery shows before the app has run.
    static var preview: ActivitySnapshot {
        let now = Date.now
        let working = [
            Item(sessionId: "a", title: "Ship the release", agentId: "claude", folder: "happier", state: .working,
                 since: now.addingTimeInterval(-245), link: nil),
            Item(sessionId: "b", title: "Fix the flaky test", agentId: "codex", folder: "radar", state: .working,
                 since: now.addingTimeInterval(-62), link: nil),
        ]
        let recent = working + [
            Item(sessionId: "c", title: "Review the PR", agentId: "claude", folder: "sculpi", state: .waiting,
                 since: now.addingTimeInterval(-600), link: nil),
            Item(sessionId: "d", title: "Write the changelog", agentId: "codex", folder: "kineos", state: .unread,
                 since: now.addingTimeInterval(-1800), link: nil),
        ]
        let usage = [
            Usage(providerId: "claude", plan: "Max", meter: "weekly", usedPercent: 64, resetsAt: now.addingTimeInterval(86_400), fetchedAt: now),
            Usage(providerId: "codex", plan: "Pro", meter: "five_hour", usedPercent: 28, resetsAt: now.addingTimeInterval(7_200), fetchedAt: now),
        ]
        return ActivitySnapshot(working: working, recent: recent, usage: usage, updatedAt: now)
    }
}

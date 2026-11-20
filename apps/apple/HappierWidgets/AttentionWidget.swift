import HappierKit
import SwiftUI
import WidgetKit

@main
struct HappierWidgets: WidgetBundle {
    var body: some Widget {
        AttentionWidget()
        TasksWidget()
        WorkingWidget()
        RecentWidget()
        UsageWidget()
        NewSessionWidget()
        #if os(iOS)
        NewSessionControl()
        ReadAloudLiveActivity()
        #endif
    }
}

/// "Needs you": how many sessions are waiting on you and which, most urgent first. Tapping a
/// session opens it; tapping elsewhere opens Happier's notifications.
struct AttentionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "happier.attention", provider: AttentionProvider()) { entry in
            AttentionWidgetView(entry: entry)
        }
        .configurationDisplayName("Needs You")
        .description("Sessions waiting for your approval or with replies you haven't read.")
        #if os(iOS)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
        #else
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        #endif
    }
}

struct AttentionEntry: TimelineEntry {
    let date: Date
    /// Nil until the app has run once on this device.
    let snapshot: AttentionSnapshot?
}

struct AttentionProvider: TimelineProvider {
    func placeholder(in context: Context) -> AttentionEntry { AttentionEntry(date: .now, snapshot: .preview) }

    func getSnapshot(in context: Context, completion: @escaping (AttentionEntry) -> Void) {
        completion(AttentionEntry(date: .now, snapshot: context.isPreview ? .preview : AttentionSnapshot.load() ?? .preview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AttentionEntry>) -> Void) {
        // The app reloads the widget whenever what's waiting changes; this only re-reads now and then.
        let entry = AttentionEntry(date: .now, snapshot: AttentionSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

/// Opens the notifications in the app.
let inboxURL = URL(string: "happier-native://inbox")!

struct AttentionWidgetView: View {
    let entry: AttentionEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: AttentionSnapshot? { entry.snapshot }
    private var total: Int { snapshot?.total ?? 0 }
    private var items: [AttentionSnapshot.Item] { snapshot?.items ?? [] }
    private var waiting: Int { items.filter { $0.reason == .waitingForYou }.count }

    var body: some View {
        content
            .widgetURL(inboxURL)
            .containerBackground(for: .widget) { background }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .systemMedium: medium
        case .systemLarge: large
        #if os(iOS)
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: Text(total == 0 ? "Happier · all caught up" : "Happier · \(total) need you")
        #endif
        default: small
        }
    }

    /// A faint wash of the app's blue, warmer when something is waiting for an approval.
    private var background: some View {
        LinearGradient(colors: [(waiting > 0 ? Color.orange : Color.blue).opacity(0.22), Color.clear],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .background(.background)
    }

    // MARK: Home Screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            Spacer(minLength: 0)
            count
            if let first = items.first {
                Text(first.title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                header
                Spacer(minLength: 0)
                count
            }
            .frame(width: 104, alignment: .leading)
            if items.isEmpty {
                caughtUp
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items.prefix(3)) { SessionRow(item: $0) }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                header
                Spacer()
                Text("\(total)")
                    .font(.title2.weight(.bold).monospacedDigit())
                    .contentTransition(.numericText())
                    .widgetAccentable()
            }
            Text(caption).font(.caption).foregroundStyle(.secondary)
            if items.isEmpty {
                caughtUp
            } else {
                ForEach(items.prefix(6)) { SessionRow(item: $0) }
            }
            Spacer(minLength: 0)
            if let updated = snapshot?.updatedAt {
                Text("Updated \(updated, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image("Logo").resizable().scaledToFit().frame(width: 16, height: 16)
            Text("Happier").font(.caption.weight(.semibold))
            if waiting > 0 {
                Image(systemName: "hand.raised.fill").font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    private var count: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(total)")
                .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
                .widgetAccentable()
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var caption: String {
        if snapshot == nil { return String(localized: "Open Happier to start") }
        switch total {
        case 0: return String(localized: "All caught up")
        case 1: return String(localized: "session needs you")
        default: return String(localized: "sessions need you")
        }
    }

    private var caughtUp: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
            Text("Nothing is waiting for you.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Lock Screen

    #if os(iOS)
    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: -1) {
                Image("Logo").resizable().scaledToFit().frame(width: 14, height: 14)
                Text("\(total)").font(.title3.weight(.bold).monospacedDigit())
            }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image("Logo").resizable().scaledToFit().frame(width: 12, height: 12)
                Text(total == 0 ? "All caught up" : "\(total) need you").font(.headline)
            }
            if let first = items.first {
                Text(first.title).font(.caption).lineLimit(1)
                Text(first.reason == .waitingForYou ? "Waiting for you" : "New reply").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    #endif
}

/// One waiting session: its agent, its title and why it's waiting; tapping opens it.
private struct SessionRow: View {
    let item: AttentionSnapshot.Item


    var body: some View {
        Link(destination: item.link ?? inboxURL) {
            HStack(spacing: 8) {
                AgentBadge(agentId: item.agentId, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: item.reason == .waitingForYou ? "hand.raised.fill" : "circle.fill")
                            .font(.system(size: item.reason == .waitingForYou ? 9 : 6))
                            .foregroundStyle(item.reason == .waitingForYou ? Color.orange : Color.blue)
                        Text(item.reason == .waitingForYou ? "Waiting for you" : "New reply")
                        Text("·")
                        Text(item.date, style: .relative)
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

extension AttentionSnapshot {
    /// What the widget gallery shows before the app has run.
    static var preview: AttentionSnapshot {
        let now = Date.now
        return AttentionSnapshot(total: 3, items: [
            Item(sessionId: "a", title: "Deploy the release", agentId: "claude", reason: .waitingForYou, date: now.addingTimeInterval(-120), link: nil),
            Item(sessionId: "b", title: "Fix the flaky test", agentId: "codex", reason: .unread, date: now.addingTimeInterval(-900), link: nil),
            Item(sessionId: "c", title: "Write the changelog", agentId: "claude", reason: .unread, date: now.addingTimeInterval(-3600), link: nil),
        ], updatedAt: now)
    }
}


// MARK: - My Tasks

/// "My Tasks": the user's open tasks, overdue first, then by due date. Tapping a task opens its
/// detail in the app; tapping elsewhere opens the Tasks list. Read-only for now.
struct TasksWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "happier.tasks", provider: TasksProvider()) { entry in
            TasksWidgetView(entry: entry)
        }
        .configurationDisplayName("My Tasks")
        .description("Your open tasks: overdue first, then by due date.")
        #if os(iOS)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular])
        #else
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        #endif
    }
}

struct TasksEntry: TimelineEntry {
    let date: Date
    /// Nil until the app has published tasks on this device.
    let snapshot: TaskWidgetSnapshot?
}

struct TasksProvider: TimelineProvider {
    func placeholder(in context: Context) -> TasksEntry { TasksEntry(date: .now, snapshot: .preview) }

    func getSnapshot(in context: Context, completion: @escaping (TasksEntry) -> Void) {
        completion(TasksEntry(date: .now, snapshot: context.isPreview ? .preview : TaskWidgetSnapshot.load() ?? .preview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TasksEntry>) -> Void) {
        // The app reloads the widget when the tasks change; this redraws when the next one falls due
        // (so it shows as overdue on time) and otherwise re-reads now and then.
        let snapshot = TaskWidgetSnapshot.load()
        let nextDue = snapshot?.items.compactMap(\.dueAt).filter { $0 > .now }.min()
        let refresh = min(nextDue ?? .distantFuture, Date.now.addingTimeInterval(30 * 60))
        completion(Timeline(entries: [TasksEntry(date: .now, snapshot: snapshot)], policy: .after(refresh)))
    }
}

extension TaskWidgetSnapshot {
    static let preview = TaskWidgetSnapshot(total: 3, overdue: 1, items: [
        Item(id: "1", title: "Comprar el cable USB-C", status: "To do", dueAt: .now.addingTimeInterval(-3_600),
             link: TaskWidgetSnapshot.taskURL(id: "1")),
        Item(id: "2", title: "Revisar la propuesta", status: "In progress", dueAt: .now.addingTimeInterval(86_400),
             link: TaskWidgetSnapshot.taskURL(id: "2")),
    ], updatedAt: .now)
}

struct TasksWidgetView: View {
    let entry: TasksEntry
    @Environment(\.widgetFamily) private var family

    private var items: [TaskWidgetSnapshot.Item] { entry.snapshot?.items ?? [] }
    private var total: Int { entry.snapshot?.total ?? 0 }
    private var overdue: Int { items.filter { $0.isOverdue(at: entry.date) }.count }

    var body: some View {
        content
            .widgetURL(TaskWidgetSnapshot.tasksURL)
            .containerBackground(for: .widget) {
                LinearGradient(colors: [(overdue > 0 ? Color.red : Color.green).opacity(0.18), Color.clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .background(.background)
            }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .systemMedium: list(limit: 3)
        case .systemLarge: list(limit: 6)
        #if os(iOS)
        case .accessoryCircular:
            Gauge(value: Double(min(total, 9)), in: 0...9) {
                Image(systemName: "checklist")
            } currentValueLabel: {
                Text("\(total)").monospacedDigit()
            }
            .gaugeStyle(.accessoryCircular)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label(total == 0 ? "No tasks" : "\(total) open", systemImage: "checklist")
                    .font(.caption.weight(.semibold))
                if let next = items.first {
                    Text(next.title).font(.caption).lineLimit(1)
                    if let due = next.dueAt { dueText(due, overdue: next.isOverdue(at: entry.date)).font(.caption2) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        #endif
        default: small
        }
    }

    private var header: some View {
        Label("My Tasks", systemImage: "checklist")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Spacer(minLength: 0)
            Text("\(total)")
                .font(.largeTitle.weight(.bold).monospacedDigit())
                .widgetAccentable()
            if overdue > 0 {
                Text("\(overdue) overdue").font(.caption2.weight(.semibold)).foregroundStyle(.red)
            }
            if let first = items.first {
                Text(first.title).font(.caption2.weight(.medium)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func list(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                header
                Spacer()
                Text("\(total)").font(.title3.weight(.bold).monospacedDigit()).widgetAccentable()
            }
            if items.isEmpty {
                Text("Nothing pending").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(items.prefix(limit)) { item in
                    Link(destination: item.link) { row(item) }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func row(_ item: TaskWidgetSnapshot.Item) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
            HStack(spacing: 6) {
                Text(item.status)
                if let due = item.dueAt { dueText(due, overdue: item.isOverdue(at: entry.date)) }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func dueText(_ due: Date, overdue: Bool) -> some View {
        Text(overdue ? "Overdue · \(due.formatted(.relative(presentation: .named)))" : "Due \(due.formatted(.relative(presentation: .named)))")
            .foregroundStyle(overdue ? Color.red : Color.secondary)
    }
}

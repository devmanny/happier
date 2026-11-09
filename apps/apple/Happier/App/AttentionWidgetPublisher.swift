import HappierKit
import SwiftUI
import WidgetKit

/// Keeps the Home Screen widgets current: whenever what's waiting on you changes, it leaves them
/// the new list in the shared App Group and asks them to redraw. It publishes at most once a
/// minute, after a burst settles (`WidgetPublishPace`): with dozens of sessions streaming,
/// recomputing on every change kept the CPU busy, and each reload wakes the widgets and the watch.
struct AttentionWidgetPublisher: View {
    @Environment(HappierStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var lastPublishedAt: Date?

    /// What the widgets show, per session: waiting for you, unread, and the title (and, for the
    /// watch, the first request and the agent's last words where the conversation is loaded).
    private var signature: [String] {
        store.sessions.values.compactMap { session -> String? in
            guard session.isUserFacing else { return nil }
            let requests = session.agentState["requests"]?.objectValue
            let waiting = requests?.isEmpty == false
            guard waiting || session.unreadSince != nil else { return nil }
            let request = requests?.keys.sorted().first ?? ""
            let words = store.transcripts[session.id]?.lastAgentText ?? ""
            return "\(session.id)|\(waiting)|\(request)|\(session.title)|\(session.unreadSince?.timeIntervalSince1970 ?? 0)|\(words.hashValue)"
        }
        .sorted()
    }

    /// Each loaded conversation's last agent text, for the watch.
    private var excerpts: [String: String] {
        var excerpts: [String: String] = [:]
        for session in store.sessionList {
            if let text = store.transcripts[session.id]?.lastAgentText { excerpts[session.id] = text }
        }
        return excerpts
    }

    /// What the Working Now, Recent and Usage widgets show, per session and provider.
    private var activity: [String] {
        let now = store.presenceDate()
        let sessions = store.sessions.values.filter(\.isUserFacing).map { session in
            "\(session.id)|\(session.status(at: now))|\(session.unreadSince != nil)|\(session.title)|\(session.thinkingAt?.timeIntervalSince1970 ?? 0)"
        }
        let usage = store.providerUsage.values.map { "\($0.providerId ?? "")|\($0.fetchedAt?.timeIntervalSince1970 ?? 0)" }
        return (sessions + usage).sorted()
    }

    /// What My Tasks shows: the user's tasks, by status, title and due date.
    private var tasks: [String] {
        store.tasks.filter { $0.assignee == .user }
            .map { "\($0.id)|\($0.status.rawValue)|\($0.title)|\($0.dueAt ?? 0)" }
            .sorted()
    }

    /// The conversations the share extension offers, as listed here.
    private var targets: [String] {
        store.sessionList.prefix(100).map { "\($0.id)|\($0.title)" }
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task { await follow() }
            // Tasks are read once at launch; after that they arrive live from the socket, and each
            // (re)connection, including coming back to the foreground, catches up through the
            // account's change cursor (`runSync`), so the foreground doesn't do it a second time.
            .task { await store.refreshTasks() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { publish() }
            }
            .onDisappear {
                // Signed out: the widgets forget this account's sessions.
                AttentionSnapshot(total: 0, items: [], updatedAt: .now).save()
                ShareTargets(sessions: []).save()
                ActivitySnapshot(working: [], recent: [], usage: [], updatedAt: .now).save()
                TaskWidgetSnapshot(total: 0, overdue: 0, items: [], updatedAt: .now).save()
                WidgetCenter.shared.reloadAllTimelines()
                #if os(iOS)
                WatchBridge.shared.publish(WatchContext(attention: AttentionSnapshot(total: 0, items: [], updatedAt: .now),
                                                        activity: ActivitySnapshot(working: [], recent: [], usage: [], updatedAt: .now)))
                #endif
            }
    }

    /// Waits for the sessions to change, lets the burst settle, then publishes what differs.
    private func follow() async {
        var last: (signature: [String], activity: [String], targets: [String], tasks: [String])?
        while !Task.isCancelled {
            if last != nil {
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        // Every entry: `values` observes them all.
                        _ = store.sessions.values
                        _ = store.transcripts.values
                        _ = store.providerUsage
                        _ = store.tasks
                    } onChange: {
                        continuation.resume()
                    }
                }
                let wait = WidgetPublishPace.wait(lastPublishedAt: lastPublishedAt?.timeIntervalSince1970,
                                                  now: Date.now.timeIntervalSince1970)
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
            }
            let now = (signature: signature, activity: activity, targets: targets, tasks: tasks)
            if now.signature != last?.signature || now.activity != last?.activity || now.tasks != last?.tasks {
                lastPublishedAt = .now
            }
            if now.signature != last?.signature || now.activity != last?.activity { publish() }
            if now.tasks != last?.tasks { publishTasks() }
            if now.targets != last?.targets { ShareTargets(sessions: store.sessionList).save() }
            last = now
        }
    }

    /// My Tasks only redraws when what it shows changed.
    private func publishTasks() {
        let snapshot = TaskWidgetSnapshot(tasks: store.tasks, limit: 6)
        guard !snapshot.looksLike(TaskWidgetSnapshot.load()) else { return }
        snapshot.save()
        WidgetCenter.shared.reloadTimelines(ofKind: "happier.tasks")
    }

    /// Save both summaries before requesting one redraw for the whole batch. Publishing on
    /// background entry remains immediate so the system can suspend the app without stale data.
    private func publish() {
        let sessions = store.sessionList
        let attention = AttentionSnapshot(sessions: sessions, server: store.server, limit: 6, excerpts: excerpts)
        let activity = ActivitySnapshot(sessions: sessions, usage: Array(store.providerUsage.values), server: store.server, now: store.presenceDate())
        let attentionChanged = !attention.looksLike(AttentionSnapshot.load())
        let activityChanged = !activity.looksLike(ActivitySnapshot.load())
        if attentionChanged { attention.save() }
        if activityChanged { activity.save() }
        guard attentionChanged || activityChanged else { return }
        WidgetCenter.shared.reloadAllTimelines()

        // The watch shows the same summaries: sent only when they changed.
        #if os(iOS)
        WatchBridge.shared.publish(WatchContext(attention: attention, activity: activity))
        #endif
    }
}

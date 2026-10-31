import HappierKit
import SwiftUI
import WidgetKit

/// Keeps the Home Screen widgets current: whenever what's waiting on you changes, it leaves them
/// the new list in the shared App Group and asks them to redraw. Its own view, so only it
/// observes every session update.
struct AttentionWidgetPublisher: View {
    @Environment(HappierStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

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
        let now = Date.now
        let sessions = store.sessions.values.filter(\.isUserFacing).map { session in
            "\(session.id)|\(session.status(at: now))|\(session.unreadSince != nil)|\(session.title)|\(session.thinkingAt?.timeIntervalSince1970 ?? 0)"
        }
        let usage = store.providerUsage.values.map { "\($0.providerId ?? "")|\($0.fetchedAt?.timeIntervalSince1970 ?? 0)" }
        return (sessions + usage).sorted()
    }

    /// The conversations the share extension offers, as listed here.
    private var targets: [String] {
        store.sessionList.prefix(100).map { "\($0.id)|\($0.title)" }
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: signature) {
                // Let a burst of updates settle before redrawing the widgets.
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                publish()
            }
            .task(id: activity) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                let snapshot = ActivitySnapshot(sessions: store.sessionList, usage: Array(store.providerUsage.values), server: store.server)
                guard !snapshot.looksLike(ActivitySnapshot.load()) else { return }
                snapshot.save()
                WidgetCenter.shared.reloadAllTimelines()
                publishToWatch()
            }
            .task(id: targets) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                ShareTargets(sessions: store.sessionList).save()
            }
            .onChange(of: scenePhase) { _, phase in if phase == .background { publish() } }
            .onDisappear {
                // Signed out: the widgets forget this account's sessions.
                AttentionSnapshot(total: 0, items: [], updatedAt: .now).save()
                ShareTargets(sessions: []).save()
                ActivitySnapshot(working: [], recent: [], usage: [], updatedAt: .now).save()
                WidgetCenter.shared.reloadAllTimelines()
                #if os(iOS)
                WatchBridge.shared.publish(WatchContext(attention: AttentionSnapshot(total: 0, items: [], updatedAt: .now),
                                                        activity: ActivitySnapshot(working: [], recent: [], usage: [], updatedAt: .now)))
                #endif
            }
    }

    private func publish() {
        let snapshot = AttentionSnapshot(sessions: store.sessionList, server: store.server, limit: 6, excerpts: excerpts)
        defer { publishToWatch(attention: snapshot) }
        guard !snapshot.looksLike(AttentionSnapshot.load()) else { return }
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// The watch gets the same two snapshots whenever either changes (its own copy is on the phone
    /// until the watch is awake); on the Mac there is no watch.
    private func publishToWatch(attention: AttentionSnapshot? = nil) {
        #if os(iOS)
        let attention = attention ?? AttentionSnapshot(sessions: store.sessionList, server: store.server, limit: 6, excerpts: excerpts)
        let activity = ActivitySnapshot(sessions: store.sessionList, usage: Array(store.providerUsage.values), server: store.server)
        WatchBridge.shared.publish(WatchContext(attention: attention, activity: activity))
        #endif
    }
}

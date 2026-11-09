import HappierKit
import SwiftUI

/// One conversation in a window of its own ("Open in New Window", Mac and iPad). It reads the same
/// store as the main window, so both show every change; the main window keeps the session.
struct SessionWindow: View {
    static let id = "session"

    let sessionId: String?
    @Environment(HappierStore.self) private var store

    var body: some View {
        NavigationStack {
            if let sessionId, store.sessions.keys.contains(sessionId) {
                ChatView(sessionId: sessionId)
                    .id(sessionId)
            } else if store.phase != .ready || !store.hasLoadedSessions {
                HappierSpinner(size: HappierSpinner.hero)
            } else {
                ContentUnavailableView("Conversation Not Found", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("It may have been archived or deleted."))
            }
        }
        .environment(\.inSessionWindow, true)
        // A window restored on launch without the main one still needs the store started.
        .task { store.restore() }
        .modifier(StoreAlerts())
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }
}

extension EnvironmentValues {
    /// Inside a conversation's own window, where "Open in New Window" would only point at itself.
    @Entry var inSessionWindow = false
}

/// The store's app-wide prompts (stop confirmation, errors), shown once, in the window in front,
/// rather than in every open window at the same time.
struct StoreAlerts: ViewModifier {
    @Environment(HappierStore.self) private var store
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content
            // Cut off from the relay: said once, at the top, not as an alert; gone on reconnecting.
            .safeAreaInset(edge: .top, spacing: 0) {
                if let notice = store.offlineNotice {
                    OfflineBanner(notice: notice)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.3), value: store.offlineNotice)
            .confirmationDialog(
                store.stopRequest?.thenArchive == true ? "Stop and archive this session?" : "Stop this session?",
                isPresented: Binding(get: { appearsActive && store.stopRequest != nil }, set: { if !$0 { store.stopRequest = nil } }),
                titleVisibility: .visible,
                presenting: store.stopRequest
            ) { request in
                Button(request.thenArchive ? "Stop and Archive" : "Stop Session", role: .destructive) {
                    AppHaptics.warning()
                    Task { await store.confirmStop(request) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The agent's process on the machine will be stopped.")
            }
            // On its own view: two alerts on one view can keep the second from showing.
            .background {
                Color.clear.alert(
                    "Delete this session?",
                    isPresented: Binding(get: { appearsActive && store.deleteRequest != nil }, set: { if !$0 { store.deleteRequest = nil } }),
                    presenting: store.deleteRequest
                ) { session in
                    Button("Delete Session", role: .destructive) {
                        AppHaptics.warning()
                        Task { await store.confirmDelete(session) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { session in
                    Text("“\(session.title)” and all its messages will be permanently deleted from every device. This can't be undone.")
                }
            }
            .alert("Something went wrong", isPresented: Binding(
                get: { appearsActive && store.lastError != nil }, set: { if !$0 { store.lastError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(store.lastError ?? "")
            }
    }
}

/// This device can't reach the relay: what it means for the sessions, without blaming them.
private struct OfflineBanner: View {
    let notice: HappierStore.OfflineNotice

    var body: some View {
        Label {
            Text(notice.message)
        } icon: {
            Image(systemName: notice == .noNetwork ? "wifi.slash" : "icloud.slash")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }
}

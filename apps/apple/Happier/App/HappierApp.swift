import HappierKit
import SwiftUI

@main
struct HappierApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    #else
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase

    private var store: HappierStore { delegate.store }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(delegate.inbox)
                .task { store.restore() }
                .task(id: store.phase == .ready) {
                    if store.phase == .ready { await delegate.enablePushNotifications() }
                }
                .onChange(of: scenePhase) { _, phase in
                    // iOS freezes networking in the background; reconnect and resync on return.
                    switch phase {
                    case .active: store.appDidBecomeActive()
                    case .background: store.appDidEnterBackground()
                    default: break
                    }
                    // Notifications opened or cleared outside the app, or of sessions archived since.
                    if phase != .inactive { Task { await delegate.inbox.refresh() } }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1080, height: 720)
        #endif
    }
}

struct RootView: View {
    @Environment(HappierStore.self) private var store

    var body: some View {
        Group {
            switch store.phase {
            case .launching:
                HappierSpinner(size: HappierSpinner.hero)
            case .signedOut:
                WelcomeView()
            case .ready:
                MainView()
            }
        }
        .animation(.smooth, value: store.phase)
    }
}

struct MainView: View {
    @Environment(HappierStore.self) private var store
    @Environment(NotificationInbox.self) private var inbox
    @State private var selection: String?
    /// Conversation open when the app last ran (empty when the list was showing).
    @AppStorage("happier.lastOpenSessionId") private var lastOpenSessionId = ""
    /// The conversation reopened automatically on launch, until the user navigates elsewhere.
    @State private var restoredSessionId: String?
    /// Whether the sessions sidebar is showing (its toolbar button folds it away and back).
    @State private var columns: NavigationSplitViewVisibility = .all
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The iPhone sessions sidebar; it starts open when there is no conversation to come back to.
    @State private var drawerOpen = (UserDefaults.standard.string(forKey: "happier.lastOpenSessionId") ?? "").isEmpty
    #endif

    var body: some View {
        layout
            .onChange(of: selection) { _, id in
                // A new, unsent conversation isn't one to reopen.
                lastOpenSessionId = id == NewChat.id ? "" : id ?? ""
                if let id { inbox.remove(sessionId: id) }
                if id != restoredSessionId { restoredSessionId = nil }
                #if os(iOS)
                // Opening a conversation from anywhere (a notification, a new session) shows it;
                // losing it goes back to the sessions.
                withAnimation(.smooth(duration: 0.3)) { drawerOpen = id == nil }
                #endif
            }
            .onChange(of: store.hasLoadedSessions, initial: true) { _, _ in restoreLastSession() }
            .onChange(of: store.openRequest, initial: true) { _, id in
                guard let id else { return }
                selection = id
                store.openRequest = nil
            }
            .onChange(of: restoredSessionId.flatMap { store.transcriptErrors[$0] }) { _, error in
                // A restored conversation that can't load sends you back to the list.
                guard error != nil else { return }
                selection = nil
                restoredSessionId = nil
            }
            .confirmationDialog(
                store.stopRequest?.thenArchive == true ? "Stop and archive this session?" : "Stop this session?",
                isPresented: Binding(get: { store.stopRequest != nil }, set: { if !$0 { store.stopRequest = nil } }),
                titleVisibility: .visible,
                presenting: store.stopRequest
            ) { request in
                Button(request.thenArchive ? "Stop and Archive" : "Stop Session", role: .destructive) {
                    Task { await store.confirmStop(request) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The agent's process on the machine will be stopped.")
            }
            .alert("Something went wrong", isPresented: Binding(
                get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(store.lastError ?? "")
            }
    }

    /// iPhone: the conversation full screen with the sessions in a sliding sidebar. Mac, iPad and
    /// a large iPhone in landscape: the sessions in a glass sidebar beside it, which folds away.
    @ViewBuilder
    private var layout: some View {
        #if os(iOS)
        if sizeClass == .compact {
            SessionDrawer(selection: $selection, isOpen: $drawerOpen)
        } else {
            splitView
        }
        #else
        splitView
        #endif
    }

    /// Observe membership at the selection boundary, keeping live updates inside the chat.
    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SessionListView(selection: $selection)
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
                #endif
        } detail: {
            if selection == NewChat.id {
                NewSessionView()
            } else if let selection, store.sessions.keys.contains(selection) {
                ChatView(sessionId: selection)
                    .id(selection)
            } else if !store.hasLoadedSessions {
                HappierSpinner(size: HappierSpinner.hero)
            } else {
                ContentUnavailableView("No Conversation Selected", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Pick a session to see what your agent is up to."))
            }
        }
    }
}

extension MainView {
    /// Reopens the last conversation once the list is known; forgets it if it no longer exists.
    private func restoreLastSession() {
        guard store.hasLoadedSessions, selection == nil, !lastOpenSessionId.isEmpty else { return }
        if store.sessions[lastOpenSessionId]?.isUserFacing == true {
            restoredSessionId = lastOpenSessionId
            selection = lastOpenSessionId
        } else {
            lastOpenSessionId = ""
            #if os(iOS)
            drawerOpen = true
            #endif
        }
    }
}

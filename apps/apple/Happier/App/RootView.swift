import HappierKit
import SwiftUI

struct RootView: View {
    @Environment(HappierStore.self) private var store
    @Environment(NotificationInbox.self) private var inbox
    @Environment(BrowserModel.self) private var browser
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var multipleWindows
    @State private var shareRequests = 0
    // The optional iOS browser build must expose its address field on launch, even signed out.
    @State private var showBrowser = BrowserModel.isBrowserRole

    var body: some View {
        Group {
            switch store.phase {
            case .launching:
                HappierSpinner(size: HappierSpinner.hero)
            case .signedOut:
                WelcomeView().id(store.server)
            case .ready:
                MainView()
            }
        }
        .animation(.smooth, value: store.phase)
        .task { store.restore() }
        .onOpenURL { url in
            switch AppLink(url: url, isBrowserRole: BrowserModel.isBrowserRole) {
            case .inbox:
                showBrowser = false
                inbox.showRequested = true
            case .newSession:
                showBrowser = false
                store.openRequest = NewChat.id
            case .share:
                showBrowser = false
                shareRequests += 1
            case .session:
                showBrowser = false
                if store.handleSessionLink(url) { AppHaptics.light() }
            case .website:
                browser.show(url, forSession: nil)
                if browser.openViews == 0 {
                    BrowserModel.present(openWindow: openWindow, multipleWindows: multipleWindows, sheet: $showBrowser)
                }
            case nil:
                break
            }
        }
        .modifier(BrowserSheet(shown: $showBrowser))
        .confirmationDialog("Open on Another Relay?", isPresented: Binding(
            get: { store.sessionLinkConfirmation != nil },
            set: { if !$0, store.sessionLinkConfirmation != nil { store.cancelSessionLink() } }
        ), titleVisibility: .visible, presenting: store.sessionLinkConfirmation) { _ in
            Button("Switch Relay") { AppHaptics.light(); store.confirmSessionLink() }
                .accessibilityIdentifier("session-link-confirm-relay")
            Button("Cancel", role: .cancel) { store.cancelSessionLink() }
                .accessibilityIdentifier("session-link-cancel-relay")
        } message: { link in
            Text("This session uses \(link.server.absoluteString). Sign in there to open it. Your current relay keeps its saved sign-in.")
        }
        .modifier(StoreAlerts())
        .task(id: store.phase == .ready) {
            if store.phase == .ready, store.accountSettings == nil { await store.refreshAccountSettings() }
        }
        .background {
            if store.phase == .ready {
                AttentionWidgetPublisher()
                ShareInboxReceiver(requests: shareRequests)
            }
        }
    }
}

struct MainView: View {
    @Environment(HappierStore.self) private var store
    @Environment(NotificationInbox.self) private var inbox
    @Environment(\.appearsActive) private var appearsActive
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
    /// Settings → Experimental: the drawer, or the system's navigation, on the iPhone.
    @AppStorage(IPhoneNavigation.key) private var iPhoneNavigation = IPhoneNavigation.drawer
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
            .onChange(of: store.isOpeningSessionLink) { _, opening in
                if !opening { restoreLastSession() }
            }
            // A conversation to show (a notification, a new session): only the main window in front
            // follows it, not every main window at once; one in the back takes it when brought forward.
            .onChange(of: store.openRequest, initial: true) { _, _ in followOpenRequest() }
            .onChange(of: appearsActive) { _, _ in followOpenRequest() }
            // A conversation deleted from here or another device goes back to the sessions.
            .onChange(of: store.deletedSessionIds) { _, deleted in
                if let selection, deleted.contains(selection) { self.selection = nil }
            }
            .onChange(of: restoredSessionId.flatMap { store.transcriptErrors[$0] }) { _, error in
                // A restored conversation that can't load sends you back to the list.
                guard error != nil else { return }
                selection = nil
                restoredSessionId = nil
            }

    }

    /// iPhone: the conversation full screen with the sessions in a sliding sidebar. Mac, iPad and
    /// a large iPhone in landscape: the sessions in a glass sidebar beside it, which folds away.
    @ViewBuilder
    private var layout: some View {
        #if os(iOS)
        if sizeClass == .compact, iPhoneNavigation == .drawer {
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
    private func followOpenRequest() {
        guard appearsActive, let id = store.openRequest else { return }
        selection = id
        store.openRequest = nil
    }

    /// Reopens the last conversation once the list is known; forgets it if it no longer exists.
    private func restoreLastSession() {
        guard store.hasLoadedSessions, !store.isOpeningSessionLink, store.openRequest == nil, selection == nil, !lastOpenSessionId.isEmpty else { return }
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

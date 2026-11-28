import HappierKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct RootView: View {
    @Environment(HappierStore.self) private var store
    @Environment(NotificationInbox.self) private var inbox
    @Environment(BrowserModel.self) private var browser
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var multipleWindows
    @State private var shareRequests = 0
    @State private var showBrowser = false
    @State private var showCookieImport = false
    @State private var cookieImportID: UUID?

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
        .task {
            store.restore()
            SafariCookieInbox.shared?.prune()
            // Mac and iPad use the browser's own window and native toolbar;
            // iPhone uses its sheet. Browsing is available before sign-in.
            if BrowserModel.isBrowserRole {
                BrowserModel.present(openWindow: openWindow, multipleWindows: multipleWindows, sheet: $showBrowser)
            }
        }
        .onOpenURL { url in
            switch AppLink(url: url, isBrowserRole: BrowserModel.isBrowserRole) {
            case .inbox:
                showBrowser = false
                inbox.showRequested = true
            case .newSession:
                showBrowser = false
                store.openRequest = NewChat.id
            case .tasks:
                showBrowser = false
                store.tasksRequest = .list
            case .task(let id):
                showBrowser = false
                store.tasksRequest = .task(id)
            case .share:
                showBrowser = false
                shareRequests += 1
            case .browserImport(let id):
                showBrowser = false
                cookieImportID = id
                showCookieImport = true
            case .session:
                showBrowser = false
                if store.handleSessionLink(url) { AppHaptics.light() }
            case .terminalConnect:
                showBrowser = false
                if store.handleTerminalConnectLink(url.absoluteString) { AppHaptics.light() }
            case .keyboardDictation:
                #if os(iOS)
                showBrowser = false
                AppDelegate.current?.keyboard.openedFromKeyboard()
                #endif
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
        #if os(iOS)
        .modifier(DictationKeyboardSheet())
        #endif
        .sheet(isPresented: $showCookieImport) {
            NavigationStack { SafariCookieImportView(requestID: cookieImportID) }
        }
        // A computer's `happier auth login` link: confirmed once signed in (on its relay, when the
        // approval had to switch and sign in there first).
        .sheet(item: Binding(
            get: { store.phase == .ready ? store.pendingTerminalConnect : nil },
            set: { if $0 == nil, store.phase == .ready { store.cancelTerminalConnect() } }
        )) { link in
            NavigationStack {
                TerminalConnectView(link: link, allowsLoopbackRelay: true) { store.cancelTerminalConnect() }
                    .sheetCloseButton()
            }
            #if os(macOS)
            .frame(minWidth: 440, minHeight: 360)
            #endif
        }
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
    @State private var conversation = WindowConversation()
    /// Conversation open when the app last ran (empty when the list was showing).
    @AppStorage("happier.lastOpenSessionId") private var lastOpenSessionId = ""
    /// The conversation reopened automatically on launch, until the user navigates elsewhere.
    @State private var restoredSessionId: String?
    /// Whether the sessions sidebar is showing (its toolbar button folds it away and back).
    @State private var columns: NavigationSplitViewVisibility = .all
    /// The Tasks panel on the right (iPad and Mac), remembered across launches.
    @AppStorage("happier.tasksPanelOpen") private var tasksPanelOpen = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The iPhone sessions sidebar; it starts open when there is no conversation to come back to.
    @State private var drawerOpen = (UserDefaults.standard.string(forKey: "happier.lastOpenSessionId") ?? "").isEmpty
    /// Settings → Experimental: the drawer, or the system's navigation, on the iPhone.
    @AppStorage(IPhoneNavigation.key) private var iPhoneNavigation = IPhoneNavigation.drawer
    #endif

    var body: some View {
        layout
            .environment(\.windowConversation, conversation)
            .onAppear { conversation.show = { selection = $0 } }
            .onChange(of: selection) { _, id in
                // A new, unsent conversation or an agent's profile isn't one to reopen.
                lastOpenSessionId = Self.sessionId(in: id) ?? ""
                inbox.onScreen = id
                if let id { inbox.remove(shownIn: id) }
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
                // A restored conversation that can't load sends you back to the list; cut off from
                // the relay it stays, with what's cached and the offline notice.
                guard error != nil, store.reachesRelay else { return }
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
            detailWithTasksPanel
        }
        .environment(\.tasksPanelAvailable, tasksPanelAvailable)
        // The My Tasks widget (or a link) asks for Tasks: open the panel, which shows what was asked.
        .onChange(of: store.tasksRequest) { _, request in
            if request != nil, tasksPanelAvailable { tasksPanelOpen = true }
        }
    }

    /// The Tasks panel on the right shows now (`TasksPanel`); otherwise Tasks is a sheet.
    private var tasksPanelAvailable: Bool {
        #if os(iOS)
        TasksPanel.shows(on: UIDevice.current.userInterfaceIdiom, sizeClass: sizeClass)
        #else
        true
        #endif
    }

    @ViewBuilder
    private var detailWithTasksPanel: some View {
        #if os(iOS)
        let hostsPanel = TasksPanel.isPart(of: UIDevice.current.userInterfaceIdiom)
        #else
        let hostsPanel = true
        #endif
        if hostsPanel {
            // Attached whatever the width, shown only where it fits: a resize only shows or hides it.
            detail
                .inspector(isPresented: Binding(get: { tasksPanelAvailable && tasksPanelOpen },
                                                set: { open in if tasksPanelAvailable { tasksPanelOpen = open } })) {
                    TasksView(presentation: .panel, openSessionId: openSessionId)
                        .inspectorColumnWidth(min: 300, ideal: 360, max: 480)
                }
                .toolbar {
                    if tasksPanelAvailable {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                AppHaptics.light()
                                tasksPanelOpen.toggle()
                            } label: {
                                Label(tasksPanelOpen ? "Hide Tasks" : "Show Tasks", systemImage: "checklist")
                            }
                            .help(Text(tasksPanelOpen ? "Hide Tasks" : "Show Tasks"))
                            .keyboardShortcut("t", modifiers: [.command, .option])
                        }
                    }
                }
        } else {
            detail
        }
    }

    /// The conversation open in the detail, if what's selected is one.
    private var openSessionId: String? { Self.sessionId(in: selection) }

    /// The session a sidebar selection names: not a new chat, an agent's profile or a room.
    static func sessionId(in selection: String?) -> String? {
        guard let selection, selection != NewChat.id, AgentProfile.id(inSelection: selection) == nil,
              AgentRoom.id(inSelection: selection) == nil else { return nil }
        return selection
    }

    @ViewBuilder
    private var detail: some View {
        if selection == NewChat.id {
            NewSessionView()
        } else if let agentId = AgentProfile.id(inSelection: selection) {
            // Its chat, in the detail column as a conversation is; its info opens from the chat's header.
            AgentChatView(agentId: agentId)
                .id(agentId)
        } else if let roomId = AgentRoom.id(inSelection: selection) {
            // A notification about an agent's chat opens it as its circle does.
            if let agentId = store.room(id: roomId)?.directAgentId {
                AgentChatView(agentId: agentId)
                    .id(agentId)
            } else {
                RoomView(roomId: roomId)
                    .id(roomId)
            }
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

#if os(iOS)
/// Where Tasks goes on iOS: a panel on the right on the iPad, in a window wide enough; a sheet on
/// the iPhone, a large one in landscape too. There it has an iPad's width, and the panel (a split
/// view inside the sidebar's) closed the app as the phone turned: UIKit's split view asserted
/// while adapting to the new width (`_performLayoutForSplitViewControllerColumn`, iOS 27.3 beta).
enum TasksPanel {
    /// Whether the panel is part of the layout: fixed for the device, so turning or resizing never
    /// adds or removes it while the split views adapt.
    static func isPart(of idiom: UIUserInterfaceIdiom) -> Bool { idiom == .pad }

    static func shows(on idiom: UIUserInterfaceIdiom, sizeClass: UserInterfaceSizeClass?) -> Bool {
        isPart(of: idiom) && sizeClass == .regular
    }
}
#endif

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

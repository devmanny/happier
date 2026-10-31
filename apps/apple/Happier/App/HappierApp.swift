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
                .modifier(BrowserReadiness())
                .environment(store)
                .environment(delegate.inbox)
                .environment(delegate.browser)
                .modifier(FollowsAppAppearance())
                .task(id: store.phase == .ready) {
                    guard store.phase == .ready else { return }
                    await delegate.enablePushNotifications()
                }
                .onChange(of: scenePhase) { _, phase in
                    // iOS freezes networking in the background; reconnect and resync on return.
                    switch phase {
                    case .active:
                        MessageSpeaker.shared.appMovedToBackground(false)
                        store.appDidBecomeActive()
                        delegate.browser.appBecameActive()
                        // Folder colors and other synced settings changed elsewhere show up here.
                        if store.phase == .ready { Task { await store.refreshAccountSettings() } }
                    case .background:
                        MessageSpeaker.shared.appMovedToBackground(true)
                        delegate.browser.appEnteredBackground()
                        store.appDidEnterBackground()
                    default: break
                    }
                    // Notifications opened or cleared outside the app, or of sessions archived since.
                    if phase != .inactive { Task { await delegate.inbox.refresh() } }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1080, height: 720)
        #endif

        WindowGroup("Conversation", id: SessionWindow.id, for: String.self) { $sessionId in
            SessionWindow(sessionId: sessionId)
                .environment(store)
                .environment(delegate.inbox)
                .environment(delegate.browser)
                .modifier(FollowsAppAppearance())
        }
        #if os(macOS)
        .defaultSize(width: 760, height: 720)
        #endif

        // The integrated browser in its own window (Mac, iPad); always the one "main" window.
        WindowGroup("Browser", id: BrowserWindow.id, for: String.self) { _ in
            BrowserWindow()
                .environment(store)
                .environment(delegate.browser)
                .modifier(FollowsAppAppearance())
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 800)
        .commands { BrowserCommands() }
        #endif

        #if os(macOS)
        // Happier → Settings… (⌘,): the same settings as the sidebar's gear button.
        Settings {
            NavigationStack { SettingsView(inSheet: false) }
                .frame(minWidth: 480, minHeight: 560)
                .environment(store)
                .environment(delegate.inbox)
                .environment(delegate.browser)
                .modifier(FollowsAppAppearance())
        }
        #endif
    }
}

#if os(macOS)
/// Window → Browser (⇧⌘B).
private struct BrowserCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(before: .windowList) {
            Button("Browser") { openWindow(id: BrowserWindow.id, value: BrowserWindow.value) }
                .keyboardShortcut("b", modifiers: [.command, .shift])
        }
    }
}
#endif

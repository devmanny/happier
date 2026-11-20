import HappierKit
import os
import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Owns the store so the platform delegate callbacks (APNs token, notification taps) can reach it.
@MainActor
final class AppDelegate: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    /// The running app's delegate, for App Intents (Siri, Shortcuts) that run inside the app.
    private(set) static weak var current: AppDelegate?
    let store = HappierStore()
    lazy var inbox = NotificationInbox(store: store)
    /// The integrated browser, shared by every window and served to session agents over the relay.
    lazy var browser: BrowserModel = {
        let browser = BrowserModel()
        browser.store = store
        store.deviceBrowserHost = browser
        return browser
    }()
    #if os(iOS)
    private var backgroundUploads: BackgroundUploads?
    #endif
    private var metricKitReports: MetricKitReports?
    private let log = Logger(subsystem: "dev.happier.apple", category: "push")

    /// Asks for notification permission (first time only) and registers with APNs on every launch.
    func enablePushNotifications() async {
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories(Self.categories)
        do {
            guard try await center.requestAuthorization(options: [.alert, .badge, .sound]) else { return }
        } catch {
            log.error("notification authorization failed: \(String(describing: error), privacy: .public)")
            return
        }
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #else
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }

    /// Same categories and buttons as the React Native app (`_layout.tsx`), plus a text reply on
    /// every other session notification, as in Messages.
    private static let categories: Set<UNNotificationCategory> = [
        UNNotificationCategory(identifier: PushNotifications.Category.permission, actions: [
            // Answered in the background, so they work from the lock screen and the Apple Watch
            // without opening the app; allowing asks for the device to be unlocked first.
            UNNotificationAction(identifier: PushNotifications.Action.allow, title: "Allow", options: [.authenticationRequired]),
            UNNotificationAction(identifier: PushNotifications.Action.deny, title: "Deny", options: [.destructive]),
        ], intentIdentifiers: []),
        UNNotificationCategory(identifier: PushNotifications.Category.userAction, actions: [
            UNNotificationAction(identifier: PushNotifications.Action.open, title: "Answer", options: [.foreground]),
        ], intentIdentifiers: []),
        UNNotificationCategory(identifier: PushNotifications.Category.sessionMessage, actions: [
            UNTextInputNotificationAction(identifier: PushNotifications.Action.reply, title: "Reply", options: [],
                                          textInputButtonTitle: "Send", textInputPlaceholder: "Message"),
        ], intentIdentifiers: []),
    ]

    fileprivate func didRegister(deviceToken: Data) {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        #if os(iOS)
        let profileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        #else
        let profileURL: URL? = Bundle.main.bundleURL.appending(path: "Contents/embedded.provisionprofile")
        #endif
        let development = PushNotifications.usesDevelopmentAPNs(provisioningProfile: profileURL.flatMap { try? Data(contentsOf: $0) })
        store.setPushDevice(.init(deviceToken: deviceToken, development: development, bundleId: bundleId))
    }

    fileprivate func didFailToRegister(_ error: Error) {
        log.error("APNs registration failed: \(String(describing: error), privacy: .public)")
    }

    // MARK: UNUserNotificationCenterDelegate

    // On the main actor: the system calls these on the main thread, and UIKit requires their
    // completion there too (finishing off it aborts the app when a notification is opened).

    /// Foreground banners, except for the conversation already on screen.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let tap = PushNotifications.tap(userInfo: Self.json(notification.request.content.userInfo), action: PushNotifications.defaultAction)
        let onScreen = UserDefaults.standard.string(forKey: "happier.lastOpenSessionId")
        if let sessionId = tap?.sessionId, sessionId == onScreen { return [] }
        // Once it's in Notification Center, it replaces the session's previous one in the app's list.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            await inbox.refresh()
        }
        // Settings → Notifications → While Happier Is Open (`foregroundBehavior`).
        switch store.accountSettings?.notifications.foregroundBehavior ?? .full {
        case .full: return [.banner, .list, .sound]
        case .silent: return [.list]
        case .off: return []
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        let replyText = (response as? UNTextInputNotificationResponse)?.userText
        guard let tap = PushNotifications.tap(userInfo: Self.json(content.userInfo), action: response.actionIdentifier, replyText: replyText)
        else { return }
        let handled = await store.handle(tap)
        // Not awaited: telling the system we're done shouldn't wait on the network.
        Task { await inbox.refresh() }
        if let permission = tap.permission {
            if !handled { await Self.reportUnansweredPermission(permission, to: content) }
            await finishBackgroundReply()
            return
        }
        guard let reply = tap.reply else { return }
        if !handled { await Self.reportUnsentReply(reply, to: content) }
        await finishBackgroundReply()
    }

    /// An Allow or Deny that couldn't reach the agent comes back as the request, to answer again.
    private static func reportUnansweredPermission(_ permission: PushTap.Permission, to original: UNNotificationContent) async {
        let content = UNMutableNotificationContent()
        content.title = original.title
        content.body = permission.allow
            ? String(localized: "Couldn't allow it. \(original.body)")
            : String(localized: "Couldn't deny it. \(original.body)")
        content.userInfo = original.userInfo
        content.categoryIdentifier = PushNotifications.Category.permission
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// A reply that didn't go out comes back as a notification you can answer again.
    private static func reportUnsentReply(_ text: String, to original: UNNotificationContent) async {
        let content = UNMutableNotificationContent()
        content.title = original.title
        content.body = String(localized: "Not sent: \u{201C}\(text)\u{201D}")
        content.userInfo = original.userInfo
        content.categoryIdentifier = PushNotifications.Category.sessionMessage
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Replying from the lock screen wakes the app in the background: let it go back to sleep
    /// with the connection closed cleanly, as when it is backgrounded.
    private func finishBackgroundReply() {
        #if os(iOS)
        if UIApplication.shared.applicationState == .background { store.appDidEnterBackground() }
        #endif
    }

    nonisolated static func json(_ userInfo: [AnyHashable: Any]) -> JSONValue {
        guard JSONSerialization.isValidJSONObject(userInfo),
              let data = try? JSONSerialization.data(withJSONObject: userInfo),
              let value = try? JSONValue.parse(data) else { return .null }
        return value
    }
}

#if os(iOS)
extension AppDelegate: UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Self.current = self
        UNUserNotificationCenter.current().delegate = self
        backgroundUploads = BackgroundUploads(store: store)
        metricKitReports = MetricKitReports(store: store)
        WatchBridge.shared.store = store
        WatchBridge.shared.activate()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        didFailToRegister(error)
    }
}
#else
extension AppDelegate: NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.current = self
        UNUserNotificationCenter.current().delegate = self
        metricKitReports = MetricKitReports(store: store)
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        didRegister(deviceToken: deviceToken)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        didFailToRegister(error)
    }
}
#endif

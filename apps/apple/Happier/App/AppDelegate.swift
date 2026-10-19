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
final class AppDelegate: NSObject, UNUserNotificationCenterDelegate {
    let store = HappierStore()
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

    /// Same categories and buttons as the React Native app (`_layout.tsx`).
    private static let categories: Set<UNNotificationCategory> = [
        UNNotificationCategory(identifier: PushNotifications.Category.permission, actions: [
            UNNotificationAction(identifier: PushNotifications.Action.allow, title: "Allow", options: [.foreground]),
            UNNotificationAction(identifier: PushNotifications.Action.deny, title: "Deny", options: [.foreground, .destructive]),
        ], intentIdentifiers: []),
        UNNotificationCategory(identifier: PushNotifications.Category.userAction, actions: [
            UNNotificationAction(identifier: PushNotifications.Action.open, title: "Answer", options: [.foreground]),
        ], intentIdentifiers: []),
    ]

    fileprivate func didRegister(deviceToken: Data) {
        let projectId = Bundle.main.object(forInfoDictionaryKey: "HappierExpoProjectId") as? String ?? ""
        guard !projectId.isEmpty, let bundleId = Bundle.main.bundleIdentifier else {
            log.notice("push disabled: no Expo project id configured")
            return
        }
        #if os(iOS)
        let profileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        #else
        let profileURL: URL? = Bundle.main.bundleURL.appending(path: "Contents/embedded.provisionprofile")
        #endif
        let development = PushNotifications.usesDevelopmentAPNs(provisioningProfile: profileURL.flatMap { try? Data(contentsOf: $0) })
        store.setPushDevice(.init(deviceToken: deviceToken, development: development, bundleId: bundleId, expoProjectId: projectId))
    }

    fileprivate func didFailToRegister(_ error: Error) {
        log.error("APNs registration failed: \(String(describing: error), privacy: .public)")
    }

    // MARK: UNUserNotificationCenterDelegate

    // Called off the main actor; only Sendable values (the parsed tap) cross back to the store.

    /// Foreground banners, except for the conversation already on screen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let tap = PushNotifications.tap(userInfo: Self.json(notification.request.content.userInfo), action: PushNotifications.defaultAction)
        let onScreen = UserDefaults.standard.string(forKey: "happier.lastOpenSessionId")
        if let sessionId = tap?.sessionId, sessionId == onScreen { return [] }
        return [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = Self.json(response.notification.request.content.userInfo)
        guard let tap = PushNotifications.tap(userInfo: userInfo, action: response.actionIdentifier) else { return }
        await store.handle(tap)
    }

    private nonisolated static func json(_ userInfo: [AnyHashable: Any]) -> JSONValue {
        guard JSONSerialization.isValidJSONObject(userInfo),
              let data = try? JSONSerialization.data(withJSONObject: userInfo),
              let value = try? JSONValue.parse(data) else { return .null }
        return value
    }
}

#if os(iOS)
extension AppDelegate: UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
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
        UNUserNotificationCenter.current().delegate = self
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        didRegister(deviceToken: deviceToken)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        didFailToRegister(error)
    }
}
#endif

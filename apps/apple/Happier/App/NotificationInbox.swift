import HappierKit
import SwiftUI
import UserNotifications

/// The in-app notification center: the app's notifications still on the device, the newest of
/// each session or room. The device's Notification Center is the one list behind both, so a notification
/// opened or cleared there is gone here, and one opened or deleted here leaves the device too.
@MainActor @Observable
final class NotificationInbox {
    private(set) var notifications: [DeliveredNotification] = []
    /// Asked from outside the lists (the Home Screen widget): show the notifications.
    var showRequested = false
    /// What the sidebar of the main window that last changed it selects (`MainView`): what's on
    /// screen, so its notifications come without a banner (`AppDelegate`, `PushTap.isShown`).
    @ObservationIgnored var onScreen: String?
    @ObservationIgnored private let store: HappierStore
    @ObservationIgnored private let center = UNUserNotificationCenter.current()

    init(store: HappierStore) {
        self.store = store
    }

    /// Rereads the device's list, taking off it the notifications a newer one of their session (or
    /// room) replaced and those of sessions archived or deleted since.
    func refresh() async {
        let onDevice = await center.deliveredNotifications()
        let feed = PushNotifications.latestPerSession(onDevice.map(Self.entry))
        // Another relay's sessions can't be checked against this one.
        let otherRelay = Set(onDevice.filter { !isFromThisRelay($0) }.map(\.request.identifier))
        var kept: [DeliveredNotification] = []
        var stale = feed.stale
        for notification in feed.latest {
            if !otherRelay.contains(notification.id), let sessionId = notification.sessionId,
               await store.isArchivedOrDeleted(sessionId) {
                stale.append(notification.id)
            } else {
                kept.append(notification)
            }
        }
        if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
        notifications = kept
    }

    func remove(_ notification: DeliveredNotification) {
        notifications.removeAll { $0.id == notification.id }
        center.removeDeliveredNotifications(withIdentifiers: [notification.id])
    }

    /// A conversation that was opened has nothing left to tell: the notifications about what the
    /// sidebar's `selection` shows (its session, its room, or the agent's chat), by the same rule
    /// that leaves out their banners (`PushTap.isShown`).
    func remove(shownIn selection: String) {
        let shown = { (notification: DeliveredNotification) in
            PushTap(sessionId: notification.sessionId, roomId: notification.roomId, permission: nil).isShown(in: selection)
        }
        notifications.removeAll(where: shown)
        Task {
            let ids = await center.deliveredNotifications().map(Self.entry).filter(shown).map(\.id)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    func removeAll() {
        notifications = []
        center.removeAllDeliveredNotifications()
    }

    private func isFromThisRelay(_ notification: UNNotification) -> Bool {
        let userInfo = AppDelegate.json(notification.request.content.userInfo)
        let data = userInfo["body"]?.objectValue != nil ? userInfo["body"]! : userInfo
        guard let server = data["serverUrl"]?.stringValue.flatMap(URL.init(string:)) else { return true }
        return server.host() == store.server.host()
    }

    private nonisolated static func entry(_ notification: UNNotification) -> DeliveredNotification {
        let content = notification.request.content
        let tap = PushNotifications.tap(userInfo: AppDelegate.json(content.userInfo), action: PushNotifications.defaultAction)
        return DeliveredNotification(id: notification.request.identifier, sessionId: tap?.sessionId, roomId: tap?.roomId,
                                     title: content.title, body: content.body, date: notification.date)
    }
}

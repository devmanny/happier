import Foundation

/// What a tapped notification (or one of its action buttons) asks the app to do.
public struct PushTap: Equatable, Sendable {
    public struct Permission: Equatable, Sendable {
        public let allow: Bool
        public let requestId: String
        public let tool: String
    }

    public let sessionId: String?
    /// The room (`AgentRoom`) a room's notice is about (`completeRoomTurn`: a reply in an agent's
    /// chat, a mention, the brake), which carries no session.
    public let roomId: String?
    public let permission: Permission?
    /// Text typed into the notification's Reply field: sent to the session without opening it.
    public let reply: String?

    public init(sessionId: String?, roomId: String? = nil, permission: Permission?, reply: String? = nil) {
        self.sessionId = sessionId
        self.roomId = roomId
        self.permission = permission
        self.reply = reply
    }

    /// Whether the conversation the sidebar's `selection` shows is the one this is about (it then
    /// comes without a banner): its session, its room, or, for an agent's chat, that agent's, opened
    /// from its circle (`AgentProfile.selection`) or from a notification (`AgentRoom.selection`).
    public func isShown(in selection: String?) -> Bool {
        guard let selection else { return false }
        if let sessionId, sessionId == selection { return true }
        guard let roomId else { return false }
        if let agentId = AgentProfile.id(inSelection: selection) { return AgentRoom.directId(agentId: agentId) == roomId }
        return AgentRoom.id(inSelection: selection) == roomId
    }
}

/// A notification still on the device, as the in-app notification center lists it.
public struct DeliveredNotification: Identifiable, Equatable, Sendable {
    /// The notification request's identifier (what removes it from the device).
    public let id: String
    public let sessionId: String?
    public let roomId: String?
    public let title: String
    public let body: String
    public let date: Date

    public init(id: String, sessionId: String?, roomId: String? = nil, title: String, body: String, date: Date) {
        self.id = id
        self.sessionId = sessionId
        self.roomId = roomId
        self.title = title
        self.body = body
        self.date = date
    }
}

/// Push notifications sent by the CLI (`apps/cli/src/api/pushNotifications.ts`). The app registers
/// its APNs token at `POST /v1/push-tokens`; the CLI delivers to it directly through APNs.
public enum PushNotifications {
    /// `PUSH_NOTIFICATION_CATEGORY_IDS` / `PUSH_NOTIFICATION_ACTION_IDS` (`@happier-dev/protocol`).
    public enum Category {
        public static let permission = "happier.permissionRequest.v1"
        public static let userAction = "happier.userActionRequest.v1"
        /// Any other session notification (a finished turn): offers a text reply.
        public static let sessionMessage = "happier.sessionMessage.v1"
    }

    public enum Action {
        public static let allow = "HAPPIER_PERMISSION_ALLOW_V1"
        public static let deny = "HAPPIER_PERMISSION_DENY_V1"
        public static let open = "HAPPIER_USER_ACTION_OPEN_V1"
        public static let reply = "HAPPIER_SESSION_REPLY_V1"
    }

    /// `UNNotificationDefaultActionIdentifier` (kept here so parsing stays platform-free).
    public static let defaultAction = "com.apple.UNNotificationDefaultActionIdentifier"

    /// Development-signed builds talk to the APNs sandbox; the CLI must send there.
    public static func usesDevelopmentAPNs(provisioningProfile: Data?) -> Bool {
        guard let profile = provisioningProfile,
              let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: profile[start.lowerBound..<end.upperBound], format: nil),
              let entitlements = (plist as? [String: Any])?["Entitlements"] as? [String: Any]
        else { return false }
        let environment = entitlements["aps-environment"] ?? entitlements["com.apple.developer.aps-environment"]
        return environment as? String == "development"
    }

    /// The token registered at `/v1/push-tokens`: everything the CLI needs to call APNs directly
    /// (`parseApnsPushToken` in `apps/cli/src/api/apnsPush.ts`).
    public static func apnsToken(deviceToken: Data, development: Bool, bundleId: String) -> String {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        return "apns:\(development ? "sandbox" : "production"):\(bundleId):\(hex)"
    }

    /// `parseNotificationTap` in `notificationRouting.ts`. The push `data` travels under `body`.
    public static func tap(userInfo: JSONValue, action: String, replyText: String? = nil) -> PushTap? {
        let data = userInfo["body"]?.objectValue != nil ? userInfo["body"]! : userInfo
        let sessionId = nonEmpty(data["sessionId"]?.stringValue)
        let roomId = nonEmpty(data["roomId"]?.stringValue)
        if action == Action.reply {
            guard let sessionId, let text = replyText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { return nil }
            return PushTap(sessionId: sessionId, permission: nil, reply: text)
        }
        let allow: Bool?
        switch action {
        case Action.allow: allow = true
        case Action.deny: allow = false
        case defaultAction, Action.open: allow = nil
        default: return nil
        }
        let requestId = nonEmpty(data["requestId"]?.stringValue ?? data["permissionId"]?.stringValue)
        var permission: PushTap.Permission?
        if let allow, sessionId != nil, let requestId {
            permission = .init(allow: allow, requestId: requestId, tool: data["tool"]?.stringValue ?? "")
        }
        return PushTap(sessionId: sessionId, roomId: roomId, permission: permission)
    }

    /// Each session's newest notification, newest first (a newer one replaces the previous, as on
    /// the device with `apns-collapse-id`), and the replaced ones to take off the device. A room's
    /// notices (`PushTap.roomId`) carry no session: the newest of each room stays the same way.
    public static func latestPerSession(_ delivered: [DeliveredNotification]) -> (latest: [DeliveredNotification], stale: [String]) {
        var seen = Set<String>()
        var latest: [DeliveredNotification] = []
        var stale: [String] = []
        for notification in delivered.sorted(by: { $0.date > $1.date }) {
            if let key = notification.sessionId ?? notification.roomId.map({ "room:" + $0 }), !seen.insert(key).inserted {
                stale.append(notification.id)
            } else {
                latest.append(notification)
            }
        }
        return (latest, stale)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }
}

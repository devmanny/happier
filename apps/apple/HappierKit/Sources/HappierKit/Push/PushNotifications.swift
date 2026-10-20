import Foundation

/// What a tapped notification (or one of its action buttons) asks the app to do.
public struct PushTap: Equatable, Sendable {
    public struct Permission: Equatable, Sendable {
        public let allow: Bool
        public let requestId: String
        public let tool: String
    }

    public let sessionId: String?
    public let permission: Permission?
}

/// Push notifications sent by the CLI (`apps/cli/src/api/pushNotifications.ts`). The app registers
/// its APNs token at `POST /v1/push-tokens`; the CLI delivers to it directly through APNs.
public enum PushNotifications {
    /// `PUSH_NOTIFICATION_CATEGORY_IDS` / `PUSH_NOTIFICATION_ACTION_IDS` (`@happier-dev/protocol`).
    public enum Category {
        public static let permission = "happier.permissionRequest.v1"
        public static let userAction = "happier.userActionRequest.v1"
    }

    public enum Action {
        public static let allow = "HAPPIER_PERMISSION_ALLOW_V1"
        public static let deny = "HAPPIER_PERMISSION_DENY_V1"
        public static let open = "HAPPIER_USER_ACTION_OPEN_V1"
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
    public static func tap(userInfo: JSONValue, action: String) -> PushTap? {
        let allow: Bool?
        switch action {
        case Action.allow: allow = true
        case Action.deny: allow = false
        case defaultAction, Action.open: allow = nil
        default: return nil
        }
        let data = userInfo["body"]?.objectValue != nil ? userInfo["body"]! : userInfo
        let sessionId = nonEmpty(data["sessionId"]?.stringValue)
        let requestId = nonEmpty(data["requestId"]?.stringValue ?? data["permissionId"]?.stringValue)
        var permission: PushTap.Permission?
        if let allow, sessionId != nil, let requestId {
            permission = .init(allow: allow, requestId: requestId, tool: data["tool"]?.stringValue ?? "")
        }
        return PushTap(sessionId: sessionId, permission: permission)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }
}

import Foundation

/// What the Apple Watch asks the iPhone to do, as a WatchConnectivity message. The watch has no
/// account keys and never talks to the relay: the phone does each of these through the same
/// paths a notification's buttons use (`HappierStore.handle(PushTap)`) or the new-session screen
/// (`createSession`).
public enum WatchMessage: Equatable, Sendable {
    case permission(sessionId: String, requestId: String, tool: String, allow: Bool)
    case reply(sessionId: String, text: String)
    case newSession(text: String)

    /// Property-list form for `WCSession.sendMessage`.
    public var dictionary: [String: Any] {
        switch self {
        case .permission(let sessionId, let requestId, let tool, let allow):
            ["action": "permission", "sessionId": sessionId, "requestId": requestId, "tool": tool, "allow": allow]
        case .reply(let sessionId, let text):
            ["action": "reply", "sessionId": sessionId, "text": text]
        case .newSession(let text):
            ["action": "newSession", "text": text]
        }
    }

    public init?(dictionary: [String: Any]) {
        func text(_ key: String) -> String? {
            guard let value = (dictionary[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        switch dictionary["action"] as? String {
        case "permission":
            guard let sessionId = text("sessionId"), let requestId = text("requestId"), let allow = dictionary["allow"] as? Bool else { return nil }
            self = .permission(sessionId: sessionId, requestId: requestId, tool: dictionary["tool"] as? String ?? "", allow: allow)
        case "reply":
            guard let sessionId = text("sessionId"), let text = text("text") else { return nil }
            self = .reply(sessionId: sessionId, text: text)
        case "newSession":
            guard let text = text("text") else { return nil }
            self = .newSession(text: text)
        default:
            return nil
        }
    }

    /// The notification tap this amounts to (nil for a new session, which has its own path).
    public var pushTap: PushTap? {
        switch self {
        case .permission(let sessionId, let requestId, let tool, let allow):
            PushTap(sessionId: sessionId, permission: .init(allow: allow, requestId: requestId, tool: tool))
        case .reply(let sessionId, let text):
            PushTap(sessionId: sessionId, permission: nil, reply: text)
        case .newSession:
            nil
        }
    }
}

/// The iPhone's answer to a `WatchMessage`.
public enum WatchReply: Equatable, Sendable {
    /// Done; the session it concerned (the new one, for a new session).
    case done(sessionId: String?)
    case failed(String)

    public var dictionary: [String: Any] {
        switch self {
        case .done(let sessionId):
            var reply: [String: Any] = ["ok": true]
            if let sessionId { reply["sessionId"] = sessionId }
            return reply
        case .failed(let message):
            return ["ok": false, "error": message]
        }
    }

    public init?(dictionary: [String: Any]) {
        guard let ok = dictionary["ok"] as? Bool else { return nil }
        self = ok ? .done(sessionId: dictionary["sessionId"] as? String) : .failed(dictionary["error"] as? String ?? "")
    }
}

/// What the iPhone leaves the watch (`WCSession.updateApplicationContext`): the same two snapshots
/// the Home Screen widgets show. The watch app saves them in its own App Group for its complications.
public struct WatchContext: Equatable, Sendable {
    public let attention: AttentionSnapshot
    public let activity: ActivitySnapshot

    public init(attention: AttentionSnapshot, activity: ActivitySnapshot) {
        self.attention = attention
        self.activity = activity
    }

    public var dictionary: [String: Any] {
        var context: [String: Any] = ["v": 1]
        if let data = try? JSONEncoder().encode(attention) { context["attention"] = data }
        if let data = try? JSONEncoder().encode(activity) { context["activity"] = data }
        return context
    }

    public init?(dictionary: [String: Any]) {
        guard let attentionData = dictionary["attention"] as? Data, let activityData = dictionary["activity"] as? Data,
              let attention = try? JSONDecoder().decode(AttentionSnapshot.self, from: attentionData),
              let activity = try? JSONDecoder().decode(ActivitySnapshot.self, from: activityData) else { return nil }
        self.attention = attention
        self.activity = activity
    }

    public static func load(from defaults: UserDefaults? = UserDefaults(suiteName: AttentionSnapshot.appGroup)) -> WatchContext? {
        guard let attention = AttentionSnapshot.load(from: defaults), let activity = ActivitySnapshot.load(from: defaults) else { return nil }
        return WatchContext(attention: attention, activity: activity)
    }

    public func save(to defaults: UserDefaults? = UserDefaults(suiteName: AttentionSnapshot.appGroup)) {
        attention.save(to: defaults)
        activity.save(to: defaults)
    }

    /// Whether showing `other` instead would change anything on the watch.
    public func looksLike(_ other: WatchContext?) -> Bool {
        guard let other else { return false }
        return attention.looksLike(other.attention) && activity.looksLike(other.activity)
    }
}

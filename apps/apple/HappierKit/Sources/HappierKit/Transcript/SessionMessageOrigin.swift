import Foundation

/// Origin supplied by the existing session_message.v1 envelope, not an authenticated identity.
/// Matches packages/protocol/src/structuredMessages/sessionMessageV1.ts.
public struct SessionMessageOrigin: Equatable, Sendable {
    public let senderSessionId: String
    public let targetSessionId: String

    public static func parse(_ meta: JSONValue?) -> SessionMessageOrigin? {
        guard meta?["happier"]?["kind"]?.stringValue == "session_message.v1",
              let sender = meta?["happier"]?["payload"]?["senderSessionId"]?.stringValue,
              let target = meta?["happier"]?["payload"]?["targetSessionId"]?.stringValue,
              !sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Opaque IDs are validated for presence, never trimmed, shortened or normalized.
        return SessionMessageOrigin(senderSessionId: sender, targetSessionId: target)
    }
}

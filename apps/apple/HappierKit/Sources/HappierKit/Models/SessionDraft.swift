import Foundation

/// The unsent composer text of a session, kept on the account so it can be picked up on another
/// device (`packages/protocol/src/drafts/sessionDrafts.ts`). The record holds a field-level
/// document; this client edits its text and leaves every other field as another client wrote it.
public enum SessionDraft {
    public static func address(_ sessionId: String) -> JSONValue {
        ["kind": "session", "sessionId": .string(sessionId)]
    }

    private static func field(_ value: JSONValue) -> JSONValue {
        ["mutationId": .string(UUID().uuidString.lowercased()), "value": value]
    }

    /// A whole document with just this text.
    public static func document(text: String) -> JSONValue {
        [
            "v": 1,
            "composer": ["text": field(.string(text)), "mentions": field([]), "attachments": field([])],
            "target": ["kind": "session", "routing": [
                "recipient": field(.null), "agentContinuation": field(.null), "executionRunDelivery": field(.null),
            ]],
            "extensions": .object([:]),
        ]
    }

    /// What gets sealed: the document bound to its session.
    public static func payload(sessionId: String, document: JSONValue) -> JSONValue {
        ["v": 1, "address": address(sessionId), "document": document]
    }

    /// The document inside a payload, only when it belongs to this session.
    public static func document(fromPayload payload: JSONValue, sessionId: String) -> JSONValue? {
        guard payload["v"]?.intValue == 1, payload["address"] == address(sessionId),
              let document = payload["document"], document["target"]?["kind"]?.stringValue == "session",
              document["composer"]?["text"]?["value"]?.stringValue != nil else { return nil }
        return document
    }

    public static func text(of document: JSONValue) -> String {
        document["composer"]?["text"]?["value"]?.stringValue ?? ""
    }

    /// The document with new text (and a new mutation id for that field only); unchanged text
    /// leaves it as it is.
    public static func withText(_ text: String, in document: JSONValue) -> JSONValue {
        guard Self.text(of: document) != text else { return document }
        return setting(.string(text), at: ["composer", "text"], in: document)
    }

    /// Sets one field's value with a fresh mutation id.
    static func setting(_ value: JSONValue, at path: [String], in document: JSONValue) -> JSONValue {
        guard let key = path.first, case .object(var object) = document else { return document }
        if path.count == 1 {
            object[key] = field(value)
        } else {
            object[key] = setting(value, at: Array(path.dropFirst()), in: object[key] ?? .object([:]))
        }
        return .object(object)
    }

    /// Worth keeping: some text, a mention or attachment, or a routing choice (`isMeaningful…`).
    public static func isMeaningful(_ document: JSONValue) -> Bool {
        if !text(of: document).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        for list in ["mentions", "attachments"] where !(document["composer"]?[list]?["value"]?.arrayValue ?? []).isEmpty {
            return true
        }
        let routing = document["target"]?["routing"]?.objectValue ?? [:]
        return routing.values.contains { !($0["value"]?.isNull ?? true) }
    }

    /// A stored record (`/session-drafts/read`): present, or a tombstone left by a clear.
    public struct Record: Equatable, Sendable {
        public let revision: Int
        /// The content envelope; nil for a tombstone.
        public let content: JSONValue?

        public init?(response: JSONValue) {
            guard ["present", "deleted"].contains(response["status"]?.stringValue ?? ""),
                  let record = response["record"], let revision = record["revision"]?.intValue else { return nil }
            self.revision = revision
            content = record["content"].flatMap { $0.isNull ? JSONValue?.none : $0 }
        }
    }

    /// What a write (`/session-drafts/mutate`) came to.
    public enum Outcome: Equatable, Sendable {
        case updated(revision: Int)
        /// Someone else wrote first; `revision` is theirs (nil when the draft is gone).
        case conflict(revision: Int?)

        public init?(response: JSONValue) {
            switch response["status"]?.stringValue {
            case "updated":
                guard let revision = response["record"]?["revision"]?.intValue else { return nil }
                self = .updated(revision: revision)
            case "conflict":
                self = .conflict(revision: response["current"]?["revision"]?.intValue)
            default:
                return nil
            }
        }
    }
}

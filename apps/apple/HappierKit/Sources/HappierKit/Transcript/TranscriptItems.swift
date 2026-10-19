import Foundation

/// A decrypted transcript row (`GET /v1/sessions/:id/messages`, `new-message`).
public struct TranscriptMessage: Sendable, Equatable {
    public let id: String
    public let seq: Int
    public let localId: String?
    public let createdAt: Date
    /// Raw record: `{role, content, meta}` (`transcriptRawRecordV1.ts`).
    public let record: JSONValue

    public init(id: String, seq: Int, localId: String?, createdAt: Date, record: JSONValue) {
        self.id = id
        self.seq = seq
        self.localId = localId
        self.createdAt = createdAt
        self.record = record
    }
}

/// One rendered row of the chat, equivalent to the UI reducer's `Message` kinds.
public enum ChatItem: Identifiable, Equatable, Sendable {
    case userText(UserText)
    case agentText(AgentText)
    case toolCall(ToolCall)
    case event(TranscriptEvent)

    public var id: String {
        switch self {
        case .userText(let x): x.id
        case .agentText(let x): x.id
        case .toolCall(let x): x.itemId
        case .event(let x): x.id
        }
    }

    public var createdAt: Date {
        switch self {
        case .userText(let x): x.createdAt
        case .agentText(let x): x.createdAt
        case .toolCall(let x): x.createdAt
        case .event(let x): x.createdAt
        }
    }
}

public struct UserText: Equatable, Sendable {
    public let id: String
    /// Transcript seq of the source row; nil while the message is only queued locally.
    public var seq: Int? = nil
    public var text: String
    public let createdAt: Date
    public let localId: String?
    /// Queued locally / on the server, not yet committed to the transcript.
    public var isPending: Bool
    /// File names from `meta.happier` `attachments.v1`.
    public var attachments: [String] = []

    public init(id: String, text: String, createdAt: Date, localId: String?, isPending: Bool, attachments: [String] = []) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.localId = localId
        self.isPending = isPending
        self.attachments = attachments
    }

    /// One identity per sent message across optimistic, queued and committed states.
    public static func stableId(localId: String) -> String { "local:\(localId)" }
}

public struct AgentText: Equatable, Sendable {
    public let id: String
    public var seq: Int? = nil
    public var text: String
    public let isThinking: Bool
    public let createdAt: Date
}

public struct ToolCall: Equatable, Sendable {
    public enum State: Equatable, Sendable { case running, completed, error }

    /// Tool-use / call id (also the permission request id for Claude).
    public let id: String
    public let itemId: String
    public let name: String
    public let input: JSONValue
    /// `input.description` (Task) or ACP `_acp.title`.
    public let title: String?
    public var state: State
    public var result: JSONValue?
    public var permission: ToolPermission?
    public let createdAt: Date
}

public struct ToolPermission: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable { case pending, approved, denied, canceled }
    public enum Kind: Equatable, Sendable { case permission, userAction }

    public let id: String
    public var status: Status
    public let kind: Kind
    public var reason: String?
    public var decision: String?
}

public struct TranscriptEvent: Equatable, Sendable {
    public let id: String
    /// AgentEvent `type` (`switch`, `message`, `limit-reached`, `context-compaction`, ...).
    public let kind: String
    public let data: JSONValue
    public let createdAt: Date
}

/// An outstanding `agentState.requests` entry.
public struct PendingRequest: Identifiable, Equatable, Sendable {
    public let id: String
    public let tool: String
    public let arguments: JSONValue
    public let kind: ToolPermission.Kind
    public let createdAt: Date?
}

public extension JSONValue {
    /// Human-readable text from tool results / content arrays (`[{type:"text", text}]`, strings, objects).
    var flattenedText: String {
        switch self {
        case .string(let s): return s
        case .array(let items): return items.map(\.flattenedText).filter { !$0.isEmpty }.joined(separator: "\n")
        case .object(let o):
            if let text = o["text"]?.stringValue { return text }
            if let output = o["output"] { return output.flattenedText }
            if let content = o["content"] { return content.flattenedText }
            return (try? String(decoding: encoded(), as: UTF8.self)) ?? ""
        case .null: return ""
        case .bool(let b): return String(b)
        case .number(let n): return n.rounded() == n ? String(Int(n)) : String(n)
        }
    }
}

extension TranscriptMessage {
    public struct UnsupportedEnvelope: Error {}

    /// Decodes a stored row; content is `{t:"encrypted",c}`, `{t:"plain",v}`, or a legacy bare
    /// ciphertext string (`sessionStoredMessageContent.ts`).
    public init(row: JSONValue, session: Session) throws {
        let content = row["content"] ?? .null
        let record: JSONValue
        switch content["t"]?.stringValue {
        case "plain":
            record = content["v"] ?? .null
        case "encrypted":
            record = try Self.decrypt(content["c"]?.stringValue, session)
        case nil:
            record = try Self.decrypt(content.stringValue ?? content["ciphertext"]?.stringValue, session)
        default:
            throw UnsupportedEnvelope()
        }
        self.init(
            id: row["id"]?.stringValue ?? UUID().uuidString, seq: row["seq"]?.intValue ?? 0,
            localId: row["localId"]?.stringValue, createdAt: Session.date(row["createdAt"]) ?? .now, record: record)
    }

    private static func decrypt(_ ciphertext: String?, _ session: Session) throws -> JSONValue {
        guard let ciphertext, let cipher = session.cipher else { throw UnsupportedEnvelope() }
        return try cipher.decryptBase64(ciphertext)
    }
}

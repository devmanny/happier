import Foundation

/// `requestedAction.kind` for `POST /v2/sessions/:id/pending`.
public enum PendingAction: String, Sendable, Equatable {
    case enqueue
    case steerIfActive = "steer_if_active"
    case steerNow = "steer_now"
    /// While busy the server turns this into interrupt-and-send.
    case sendNow = "send_now"
}

/// Default send decision (`selectSessionPendingRequestedAction` with the default
/// `sessionBusySteerSendPolicy = steer_immediately`).
public enum SendDecision {
    /// Commands that must not be injected into a running turn (`isNonSteerablePromptPayload`).
    static let nonSteerableCommands: Set<String> = ["/clear", "/compact"]

    public static func action(for text: String, session: Session) -> PendingAction {
        guard session.active else { return .enqueue }
        if session.seq == 0 { return .sendNow }
        guard session.agentStateVersion > 0 else { return .enqueue }
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first.map(String.init) ?? ""
        if nonSteerableCommands.contains(command.lowercased()) { return .enqueue }
        return session.steerSupported ? .steerIfActive : .enqueue
    }
}

extension Session {
    private var capabilities: JSONValue? { agentState["capabilities"] }

    /// `inFlightSteerSupported`, falling back to the legacy `inFlightSteer` flag.
    public var steerSupported: Bool {
        capabilities?["inFlightSteerSupported"]?.boolValue ?? capabilities?["inFlightSteer"]?.boolValue ?? false
    }

    /// Steering is possible right now (`inFlightSteerAvailable`, legacy fallback).
    public var steerAvailable: Bool {
        capabilities?["inFlightSteerAvailable"]?.boolValue ?? capabilities?["inFlightSteer"]?.boolValue ?? false
    }
}

/// A row of the server pending queue (`GET /v2/sessions/:id/pending?includeDiscarded=1`).
public struct PendingMessage: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case queued
        case delivering
        case blocked(reason: String)
        case discarded
    }

    public var id: String { localId }
    public let localId: String
    public let text: String
    public let state: State
    public let createdAt: Date
    /// Decrypted raw record, kept so edits can re-encrypt it with new text.
    public let record: JSONValue?

    public static func list(_ rows: [JSONValue], session: Session) -> [PendingMessage] {
        var queued: [(position: Double, created: Double, item: PendingMessage)] = []
        var discarded: [(at: Double, item: PendingMessage)] = []
        for row in rows {
            guard let localId = row["localId"]?.stringValue else { continue }
            let isDiscarded = row["status"]?.stringValue == "discarded"
            if isDiscarded, row["discardedReason"]?.stringValue == "resent_as_new" { continue }
            let record = try? decodeRecord(row["content"], session: session)
            let text = record.flatMap { r -> String? in
                let display = r["meta"]?["displayText"]?.stringValue
                return (display?.isEmpty == false ? display : nil) ?? r["content"]?["text"]?.stringValue
            } ?? String(localized: "Couldn’t decrypt this pending message.")
            let state: State
            if isDiscarded {
                state = .discarded
            } else {
                switch row["deliveryStatus"]?["status"]?.stringValue ?? row["deliveryState"]?.stringValue {
                case "blocked":
                    state = .blocked(reason: row["deliveryBlockedReason"]?.stringValue ?? row["deliveryStatus"]?["reason"]?.stringValue ?? "unknown")
                case "delivering", "external_handoff": state = .delivering
                default: state = .queued
                }
            }
            let created = row["createdAt"]?.doubleValue ?? 0
            let item = PendingMessage(localId: localId, text: text, state: state,
                                      createdAt: Date(timeIntervalSince1970: created / 1000), record: record)
            if isDiscarded {
                discarded.append(((row["discardedAt"]?.doubleValue ?? row["updatedAt"]?.doubleValue) ?? 0, item))
            } else {
                queued.append((row["position"]?.doubleValue ?? 0, created, item))
            }
        }
        queued.sort { ($0.position, $0.created, $0.item.localId) < ($1.position, $1.created, $1.item.localId) }
        discarded.sort { $0.at < $1.at }
        return queued.map(\.item) + discarded.map(\.item)
    }

    /// New text for a queued message; drops `meta.appendSystemPrompt` like `pendingQueueV2.ts`.
    public static func editedRecord(_ record: JSONValue, text: String) -> JSONValue {
        var object = record.objectValue ?? ["role": "user"]
        var content = object["content"]?.objectValue ?? ["type": "text"]
        content["text"] = .string(text)
        object["content"] = .object(content)
        if var meta = object["meta"]?.objectValue {
            meta["appendSystemPrompt"] = nil
            if meta["displayText"] != nil { meta["displayText"] = .string(text) }
            object["meta"] = .object(meta)
        }
        return .object(object)
    }

    private static func decodeRecord(_ content: JSONValue?, session: Session) throws -> JSONValue {
        if content?["t"]?.stringValue == "plain" { return content?["v"] ?? .null }
        guard let ciphertext = content?["c"]?.stringValue ?? content?.stringValue, let cipher = session.cipher else {
            throw ContentCipher.Failure.malformed
        }
        return try cipher.decryptBase64(ciphertext)
    }
}

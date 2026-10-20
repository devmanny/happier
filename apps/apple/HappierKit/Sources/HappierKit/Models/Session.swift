import Foundation

/// A decrypted session row (`GET /v2/sessions`, `new-session`, `update-session`).
public struct Session: Identifiable, Sendable, Equatable {
    public enum Failure: Error { case missingKeys, undecryptable(String) }

    public enum Status: Equatable, Sendable {
        case permissionRequired, actionRequired, working, failed, idle, offline
    }

    public let id: String
    public var seq: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var meaningfulActivityAt: Date?
    public var active: Bool
    public var activeAt: Date?
    public var archivedAt: Date?
    public var thinking: Bool
    public var thinkingAt: Date?
    public var latestTurnStatus: String?
    public var latestTurnStatusObservedAt: Date?
    public var pendingPermissionRequestCount: Int
    public var pendingUserActionRequestCount: Int
    public var unreadSince: Date?
    public var lastViewedSessionSeq: Int?
    public var lastRuntimeIssue: JSONValue?
    public var pendingVersion: Int?
    /// User-message seqs the agent can rewind to (`rollbackEligibleTurnStarts`).
    public var rollbackEligibleTurnStarts: Set<Int>
    public var pendingCount: Int

    public var metadata: JSONValue
    public var metadataVersion: Int
    public var agentState: JSONValue
    public var agentStateVersion: Int

    public let isPlain: Bool
    /// Content cipher for E2EE sessions; nil for plaintext sessions.
    public let cipher: ContentCipher?

    public static func == (lhs: Session, rhs: Session) -> Bool {
        lhs.id == rhs.id && lhs.seq == rhs.seq && lhs.updatedAt == rhs.updatedAt && lhs.active == rhs.active
            && lhs.activeAt == rhs.activeAt && lhs.thinking == rhs.thinking && lhs.metadataVersion == rhs.metadataVersion
            && lhs.agentStateVersion == rhs.agentStateVersion && lhs.latestTurnStatus == rhs.latestTurnStatus
            && lhs.pendingPermissionRequestCount == rhs.pendingPermissionRequestCount
            && lhs.pendingUserActionRequestCount == rhs.pendingUserActionRequestCount
            && lhs.unreadSince == rhs.unreadSince && lhs.archivedAt == rhs.archivedAt
    }

    public init(row: JSONValue, keys: AccountKeys?) throws {
        guard let id = row["id"]?.stringValue else { throw Failure.undecryptable("missing id") }
        self.id = id
        isPlain = row["encryptionMode"]?.stringValue == "plain"
        if isPlain {
            cipher = nil
        } else {
            guard let keys else { throw Failure.missingKeys }
            guard let resolved = keys.cipher(forDataEncryptionKey: row["dataEncryptionKey"]?.stringValue) else {
                throw Failure.undecryptable("dataEncryptionKey")
            }
            cipher = resolved
        }
        seq = row["seq"]?.intValue ?? 0
        createdAt = Self.date(row["createdAt"]) ?? .distantPast
        updatedAt = Self.date(row["updatedAt"]) ?? .distantPast
        meaningfulActivityAt = Self.date(row["meaningfulActivityAt"])
        active = row["active"]?.boolValue ?? false
        activeAt = Self.date(row["activeAt"])
        archivedAt = Self.date(row["archivedAt"])
        thinking = row["thinking"]?.boolValue ?? false
        thinkingAt = Self.date(row["thinkingAt"])
        latestTurnStatus = row["latestTurnStatus"]?.stringValue
        latestTurnStatusObservedAt = Self.date(row["latestTurnStatusObservedAt"])
        pendingPermissionRequestCount = row["pendingPermissionRequestCount"]?.intValue ?? 0
        pendingUserActionRequestCount = row["pendingUserActionRequestCount"]?.intValue ?? 0
        unreadSince = Self.date(row["unreadSince"])
        lastViewedSessionSeq = row["lastViewedSessionSeq"]?.intValue
        lastRuntimeIssue = row["lastRuntimeIssue"].flatMap { $0.isNull ? nil : $0 }
        pendingVersion = row["pendingVersion"]?.intValue
        rollbackEligibleTurnStarts = Set((row["rollbackEligibleTurnStarts"]?.arrayValue ?? []).compactMap(\.intValue))
        pendingCount = row["pendingCount"]?.intValue ?? 0
        metadataVersion = row["metadataVersion"]?.intValue ?? 0
        agentStateVersion = row["agentStateVersion"]?.intValue ?? 0
        metadata = .null
        agentState = .null
        metadata = try decodeDocument(row["metadata"]) ?? .object([:])
        agentState = try decodeDocument(row["agentState"]) ?? .null
    }

    /// Applies an `update-session` body (only present fields are patched).
    public mutating func apply(update body: JSONValue) throws {
        if let m = body["metadata"], let version = m["version"]?.intValue, version > metadataVersion {
            metadata = try decodeDocument(m["value"]) ?? metadata
            metadataVersion = version
        }
        if let s = body["agentState"], let version = s["version"]?.intValue, version > agentStateVersion {
            agentState = try decodeDocument(s["value"]) ?? .null
            agentStateVersion = version
        }
        if let v = body["active"]?.boolValue { active = v }
        if let v = Self.date(body["activeAt"]) { activeAt = v }
        if let v = body["pendingPermissionRequestCount"]?.intValue { pendingPermissionRequestCount = v }
        if let v = body["pendingUserActionRequestCount"]?.intValue { pendingUserActionRequestCount = v }
        if let v = body["latestTurnStatus"] { latestTurnStatus = v.stringValue }
        if let v = Self.date(body["latestTurnStatusObservedAt"]) { latestTurnStatusObservedAt = v }
        if let v = body["lastViewedSessionSeq"]?.intValue { lastViewedSessionSeq = v }
        if let v = Self.date(body["meaningfulActivityAt"]) { meaningfulActivityAt = v }
        if let v = body["archivedAt"] { archivedAt = Self.date(v) }
        if let v = body["lastRuntimeIssue"] { lastRuntimeIssue = v.isNull ? nil : v }
        if let v = body["unreadSince"] { unreadSince = Self.date(v) }
        if let v = body["rollbackEligibleTurnStarts"]?.arrayValue { rollbackEligibleTurnStarts = Set(v.compactMap(\.intValue)) }
    }

    /// Applies an ephemeral `activity` event.
    public mutating func apply(activity: JSONValue) {
        if let v = activity["active"]?.boolValue { active = v }
        if let v = Self.date(activity["activeAt"]) { activeAt = v }
        if let v = activity["thinking"]?.boolValue, !isTurnTerminal {
            thinking = v
            thinkingAt = activeAt
        }
    }

    // MARK: Documents

    /// E2EE: base64 ciphertext. Plain: a JSON string (`parsePlainSessionPayload.ts`).
    func decodeDocument(_ value: JSONValue?) throws -> JSONValue? {
        guard let string = value?.stringValue, !string.isEmpty else { return nil }
        if isPlain { return try JSONValue.parse(string) }
        do { return try cipher?.decryptBase64(string) } catch { throw Failure.undecryptable("document") }
    }

    public func encodeDocument(_ value: JSONValue) throws -> String {
        if isPlain { return String(decoding: try value.encoded(), as: UTF8.self) }
        guard let cipher else { throw Failure.missingKeys }
        return try cipher.encryptBase64(value)
    }

    // MARK: Display (`apps/ui/sources/utils/sessions/sessionUtils.ts`)

    public var path: String? { metadata["path"]?.stringValue }
    public var machineId: String? { metadata["machineId"]?.stringValue }
    /// The session this one was started from (`spawnedBySessionV1`). Forks are clones, not children.
    public var parentSessionId: String? { metadata["spawnedBySessionV1"]?["parentSessionId"]?.stringValue }
    public var host: String? { metadata["host"]?.stringValue }
    public var agentId: String? { Agent.id(fromFlavor: metadata["flavor"]?.stringValue) }
    public var isUserFacing: Bool { metadata["systemSessionV1"]?["hidden"]?.boolValue != true && archivedAt == nil }
    public var permissionMode: String? { metadata["permissionMode"]?.stringValue }

    public var title: String {
        if let summary = metadata["summary"]?["text"]?.stringValue, !summary.isEmpty { return summary }
        if let name = metadata["name"]?.stringValue, !name.isEmpty { return name }
        if let path, let last = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last { return String(last) }
        return "Unknown"
    }

    public var displayPath: String? {
        guard let path else { return nil }
        if let home = metadata["homeDir"]?.stringValue, !home.isEmpty, path == home || path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    public var sortDate: Date { meaningfulActivityAt ?? updatedAt }

    private var isTurnTerminal: Bool { ["completed", "cancelled", "failed"].contains(latestTurnStatus ?? "") }

    /// Simplified `getSessionStatus` + `deriveSessionRuntimePresentationState` (120 s freshness window).
    public func status(at now: Date = .now) -> Status {
        guard active else { return .offline }
        if pendingPermissionRequestCount > 0 { return .permissionRequired }
        if pendingUserActionRequestCount > 0 { return .actionRequired }
        let fresh: (Date?) -> Bool = { date in date.map { now.timeIntervalSince($0) <= 120 } ?? false }
        if latestTurnStatus == "in_progress", fresh(latestTurnStatusObservedAt) || fresh(activeAt) { return .working }
        if thinking, !isTurnTerminal, fresh(thinkingAt ?? activeAt) { return .working }
        if latestTurnStatus == "failed" { return .failed }
        return .idle
    }

    static func date(_ value: JSONValue?) -> Date? {
        guard let ms = value?.doubleValue, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}

extension Session {
    /// Agents whose catalog entry declares `sessionRollback.conversation: 'supported'` (`packages/agents/src/manifest.ts`).
    static let rollbackAgents: Set<String> = ["codex"]

    /// "Restore to here": the CLI rewinds the live conversation, so the session must be active.
    public func canRollback(toUserMessageSeq seq: Int) -> Bool {
        active && agentId.map(Self.rollbackAgents.contains) == true && rollbackEligibleTurnStarts.contains(seq)
    }
}

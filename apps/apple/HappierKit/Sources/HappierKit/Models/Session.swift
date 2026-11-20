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
    /// Subagents and commands the agent keeps running in the background (`runtimeActivity*` on the
    /// session row, kept by the daemon).
    public var backgroundActivityCount: Int
    /// Bumped whenever that background activity changes.
    public var runtimeActivityRevision: Int

    public var metadata: JSONValue
    public var metadataVersion: Int
    public var agentState: JSONValue
    public var agentStateVersion: Int

    public let isPlain: Bool
    /// The viewer's access when someone else shared the session (`share.accessLevel`: view, edit,
    /// admin); nil for the user's own sessions (`v2SessionListRows.ts`).
    public let sharedAccessLevel: String?
    /// Content cipher for E2EE sessions; nil for plaintext sessions.
    public let cipher: ContentCipher?

    /// Every field a view shows. The metadata and agent state documents compare by version
    /// (cheap, and they only change with it); the cipher is fixed for the session. Left out: the
    /// heartbeat times (`activeAt`, `thinkingAt`, `latestTurnStatusObservedAt`), refreshed every
    /// few seconds while an agent works and only read to tell whether it still is, which the rows'
    /// and conversation's own clocks re-check. The store keeps them all the same.
    public static func == (lhs: Session, rhs: Session) -> Bool {
        lhs.id == rhs.id && lhs.seq == rhs.seq && lhs.createdAt == rhs.createdAt && lhs.updatedAt == rhs.updatedAt
            && lhs.meaningfulActivityAt == rhs.meaningfulActivityAt
            && lhs.active == rhs.active && lhs.archivedAt == rhs.archivedAt
            && lhs.thinking == rhs.thinking
            && lhs.latestTurnStatus == rhs.latestTurnStatus
            && lhs.pendingPermissionRequestCount == rhs.pendingPermissionRequestCount
            && lhs.pendingUserActionRequestCount == rhs.pendingUserActionRequestCount
            && lhs.unreadSince == rhs.unreadSince && lhs.lastViewedSessionSeq == rhs.lastViewedSessionSeq
            && lhs.lastRuntimeIssue == rhs.lastRuntimeIssue && lhs.pendingVersion == rhs.pendingVersion
            && lhs.rollbackEligibleTurnStarts == rhs.rollbackEligibleTurnStarts && lhs.pendingCount == rhs.pendingCount
            && lhs.backgroundActivityCount == rhs.backgroundActivityCount
            && lhs.runtimeActivityRevision == rhs.runtimeActivityRevision
            && lhs.metadataVersion == rhs.metadataVersion && lhs.agentStateVersion == rhs.agentStateVersion
            && lhs.isPlain == rhs.isPlain
    }

    public init(row: JSONValue, keys: AccountKeys?) throws {
        guard let id = row["id"]?.stringValue else { throw Failure.undecryptable("missing id") }
        self.id = id
        isPlain = row["encryptionMode"]?.stringValue == "plain"
        sharedAccessLevel = row["share"]?["accessLevel"]?.stringValue
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
        latestTurnStatus = row["latestTurnStatus"]?.stringValue
        // A finished turn isn't thinking, whatever its last heartbeat said.
        thinking = (row["thinking"]?.boolValue ?? false) && !Self.isTerminal(latestTurnStatus)
        thinkingAt = Self.date(row["thinkingAt"])
        latestTurnStatusObservedAt = Self.date(row["latestTurnStatusObservedAt"])
        pendingPermissionRequestCount = row["pendingPermissionRequestCount"]?.intValue ?? 0
        pendingUserActionRequestCount = row["pendingUserActionRequestCount"]?.intValue ?? 0
        unreadSince = Self.date(row["unreadSince"])
        lastViewedSessionSeq = row["lastViewedSessionSeq"]?.intValue
        lastRuntimeIssue = row["lastRuntimeIssue"].flatMap { $0.isNull ? JSONValue?.none : $0 }
        pendingVersion = row["pendingVersion"]?.intValue
        rollbackEligibleTurnStarts = Set((row["rollbackEligibleTurnStarts"]?.arrayValue ?? []).compactMap(\.intValue))
        pendingCount = row["pendingCount"]?.intValue ?? 0
        backgroundActivityCount = row["runtimeActivityState"]?.stringValue == "active" ? row["runtimeActivityActiveCount"]?.intValue ?? 0 : 0
        runtimeActivityRevision = row["runtimeActivityRevision"]?.intValue ?? 0
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
        if let v = body["latestTurnStatus"] {
            latestTurnStatus = v.stringValue
            // The turn's end can land before its last "thinking" heartbeat, which is then
            // ignored (the turn is over): it must not stay thinking (auto read waits on it).
            if isTurnTerminal { thinking = false }
        }
        if let v = Self.date(body["latestTurnStatusObservedAt"]) { latestTurnStatusObservedAt = v }
        if let v = body["lastViewedSessionSeq"]?.intValue { lastViewedSessionSeq = v }
        if let v = Self.date(body["meaningfulActivityAt"]) { meaningfulActivityAt = v }
        if let v = body["archivedAt"] { archivedAt = Self.date(v) }
        if let v = body["lastRuntimeIssue"] { lastRuntimeIssue = v.isNull ? nil : v }
        if let v = body["unreadSince"] { unreadSince = Self.date(v) }
        if let v = body["rollbackEligibleTurnStarts"]?.arrayValue { rollbackEligibleTurnStarts = Set(v.compactMap(\.intValue)) }
        if let state = body["runtimeActivityState"]?.stringValue {
            backgroundActivityCount = state == "active" ? body["runtimeActivityActiveCount"]?.intValue ?? backgroundActivityCount : 0
        } else if let count = body["runtimeActivityActiveCount"]?.intValue {
            backgroundActivityCount = count
        }
        if let v = body["runtimeActivityRevision"]?.intValue { runtimeActivityRevision = v }
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

    /// The session after a heartbeat, or nil when nothing worth redrawing changed: running
    /// sessions send one every few seconds, and applying each redrew every session list. Like the
    /// RN app's `ActivityUpdateAccumulator`, a timestamp alone counts once it is 60 s newer, half
    /// the 120 s freshness window `status(at:)` uses.
    public func applying(activity: JSONValue) -> Session? {
        var updated = self
        updated.apply(activity: activity)
        if updated.active != active || updated.thinking != thinking { return updated }
        guard let before = activeAt, let after = updated.activeAt else { return updated.activeAt == activeAt ? nil : updated }
        return after.timeIntervalSince(before) > 60 ? updated : nil
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
    /// The session the list nests this one under: where it was moved to by hand (`listParentV1`,
    /// nil there means the top level), else the session it was started from (`spawnedBySessionV1`).
    /// Forks are clones, not children.
    public var parentSessionId: String? {
        if let moved = metadata["listParentV1"], moved.objectValue != nil { return moved["parentSessionId"]?.stringValue }
        return metadata["spawnedBySessionV1"]?["parentSessionId"]?.stringValue
    }
    public var host: String? { metadata["host"]?.stringValue }
    public var agentId: String? { Agent.id(fromFlavor: metadata["flavor"]?.stringValue) }
    /// The bell is off: the session never notifies (`notificationsMutedV1`, on by default).
    public var notificationsMuted: Bool { metadata["notificationsMutedV1"]?["muted"]?.boolValue == true }
    public var isUserFacing: Bool { metadata["systemSessionV1"]?["hidden"]?.boolValue != true && archivedAt == nil }
    public var permissionMode: String? { metadata["permissionMode"]?.stringValue }
    /// The agent's own conversation id (Claude session, Codex thread…): every agent's
    /// `vendorResumeIdField` in `packages/agents/src/manifest.ts` is `<agentId>SessionId`.
    public var vendorSessionId: String? {
        agentId.flatMap { metadata["\($0)SessionId"]?.stringValue }.flatMap { $0.isEmpty ? nil : $0 }
    }

    public var title: String {
        if let summary = metadata["summary"]?["text"]?.stringValue, !summary.isEmpty { return summary }
        if let name = metadata["name"]?.stringValue, !name.isEmpty { return name }
        if let folderName { return folderName }
        return "Unknown"
    }

    /// The project folder's own name ("manny-agenda" for `~/Projects/manny-agenda`).
    public var folderName: String? {
        path?.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
    }

    /// A list row's second line: the agent it works as, then its folder (else its machine).
    public var listDetail: String {
        [agentIdentity?.name, folderName ?? host].compactMap { $0 }.joined(separator: " · ")
    }

    /// Where it works, for a list row that names the agent elsewhere: its folder, else its machine.
    public var listPlace: String { folderName ?? host ?? "" }

    public var displayPath: String? {
        guard let path else { return nil }
        if let home = metadata["homeDir"]?.stringValue, !home.isEmpty, path == home || path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    public var sortDate: Date { meaningfulActivityAt ?? updatedAt }

    /// Put to rest by the idle cleaner, not stopped by the user: `sessionRestV1` (written by
    /// `happier session stop --reason idle`, `packages/protocol/src/sessionMetadata/sessionRestV1.ts`)
    /// no older than the last start (`lifecycleStateSince`, rewritten by the runner on every start and
    /// resume). A start supersedes the rest, so the user's own stop after it reads as stopped. With no
    /// recorded start, the rest is the latest thing known. Only for a stopped session that isn't
    /// archived; everything that acts on a stopped session still sees `.offline`.
    public var isResting: Bool {
        guard !active, archivedAt == nil, let rest = metadata["sessionRestV1"], rest["v"]?.intValue == 1,
              rest["reason"]?.stringValue == "idle", let at = rest["at"]?.doubleValue else { return false }
        guard let since = metadata["lifecycleStateSince"]?.doubleValue else { return true }
        return at >= since
    }

    /// Whether the user may delete the session for good (`sessionActionContext.ts` `canDelete`):
    /// only their own, once it has stopped, and not while a preserved terminal host still holds it.
    public var canDelete: Bool {
        sharedAccessLevel == nil && !active && !hasPreservedTerminalHost
    }

    /// `resolveTerminalControlServiceabilityPolicy(...).hostPresence == 'preserved'`.
    private var hasPreservedTerminalHost: Bool {
        guard let policy = metadata["terminal"]?["controlServiceabilityV1"], policy["v"]?.intValue == 1 else { return false }
        return policy["retired"]?.boolValue != true
    }

    private var isTurnTerminal: Bool { Self.isTerminal(latestTurnStatus) }

    private static func isTerminal(_ turnStatus: String?) -> Bool { ["completed", "cancelled", "failed"].contains(turnStatus ?? "") }

    /// Whether the relay keeps sending publisher heartbeats (`activeAt`). A relay that accepted the
    /// lean updates (`updates-lean-v1`) sends only state changes, including `active: false` when a
    /// publisher stops signalling, so a turn's freshness can't be judged by `activeAt`. Set by the
    /// store once per connection.
    nonisolated(unsafe) public static var heartbeatsArrive = true

    /// Simplified `getSessionStatus` + `deriveSessionRuntimePresentationState` (120 s freshness
    /// window, while heartbeats arrive).
    public func status(at now: Date = .now, heartbeats: Bool = Session.heartbeatsArrive) -> Status {
        guard active else { return .offline }
        if pendingPermissionRequestCount > 0 { return .permissionRequired }
        if pendingUserActionRequestCount > 0 { return .actionRequired }
        let fresh: (Date?) -> Bool = { date in !heartbeats || (date.map { now.timeIntervalSince($0) <= 120 } ?? false) }
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

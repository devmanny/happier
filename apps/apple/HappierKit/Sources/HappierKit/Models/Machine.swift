import Foundation

/// A computer running the Happier daemon (`GET /v1/machines`, `machineSerialization.ts`).
public struct Machine: Identifiable, Sendable, Equatable {
    public struct Undecryptable: Error {}

    /// The daemon's own report (`daemonState`, `apps/cli/src/api/types.ts`).
    public struct Daemon: Sendable, Equatable {
        public let status: String?
        public let pid: Int?
        public let httpPort: Int?
        public let startedAt: Date?
        /// The CLI version the daemon started with.
        public let cliVersion: String?
        public var isShuttingDown: Bool { status == "shutting-down" }

        init?(_ state: JSONValue?) {
            guard let state, state.objectValue != nil else { return nil }
            status = state["status"]?.stringValue
            pid = state["pid"]?.intValue
            httpPort = state["httpPort"]?.intValue
            startedAt = state["startedAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) }
            cliVersion = state["startedWithCliVersion"]?.stringValue
        }
    }

    public let id: String
    public private(set) var active: Bool
    public private(set) var activeAt: Date?
    public private(set) var metadata: JSONValue
    public private(set) var metadataVersion: Int
    public private(set) var daemon: Daemon?
    public private(set) var daemonStateVersion: Int
    /// Removed from the account (`POST /v1/machines/:id/revoke`).
    public private(set) var revokedAt: Date?
    /// Marked as replaced by another machine; old sessions and launches go there.
    public private(set) var replacedByMachineId: String?
    public let createdAt: Date?
    /// Content cipher for machine RPC; nil for plain machines.
    let cipher: ContentCipher?

    public static func == (lhs: Machine, rhs: Machine) -> Bool {
        lhs.id == rhs.id && lhs.active == rhs.active && lhs.activeAt == rhs.activeAt && lhs.metadata == rhs.metadata
            && lhs.metadataVersion == rhs.metadataVersion && lhs.daemon == rhs.daemon
            && lhs.revokedAt == rhs.revokedAt && lhs.replacedByMachineId == rhs.replacedByMachineId
    }

    public init(row: JSONValue, keys: AccountKeys?) throws {
        guard let id = row["id"]?.stringValue else { throw Undecryptable() }
        self.id = id
        active = row["active"]?.boolValue ?? false
        activeAt = Session.date(row["activeAt"])
        metadataVersion = row["metadataVersion"]?.intValue ?? 0
        daemonStateVersion = row["daemonStateVersion"]?.intValue ?? 0
        revokedAt = Self.positiveDate(row["revokedAt"])
        replacedByMachineId = row["replacedByMachineId"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        createdAt = Session.date(row["createdAt"])
        let key = row["dataEncryptionKey"]?.stringValue
        if Self.isPlainMarker(key) {
            cipher = nil
        } else {
            guard let resolved = keys?.cipher(forDataEncryptionKey: key) else { throw Undecryptable() }
            cipher = resolved
        }
        metadata = .null
        daemon = nil
        metadata = try decode(row["metadata"]) ?? [:]
        daemon = Daemon(try decode(row["daemonState"]))
    }

    public var name: String { displayName ?? host ?? id }
    public var displayName: String? { metadata["displayName"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
    public var host: String? { metadata["host"]?.stringValue }
    public var homeDir: String? { metadata["homeDir"]?.stringValue }
    public var platform: String? { metadata["platform"]?.stringValue }
    public var cliVersion: String? { metadata["happyCliVersion"]?.stringValue }

    /// Reachable now (`isMachineOnline`): a heartbeat within the last minute, or the server's flag
    /// when there is no heartbeat time; never once revoked or replaced.
    public func isOnline(at now: Date = .now) -> Bool {
        if revokedAt != nil || replacedByMachineId != nil { return false }
        guard let activeAt else { return active }
        return now.timeIntervalSince(activeAt) <= 60
    }

    /// The machines a list shows: revoked and replaced ones are left out (`filterVisibleMachines.ts`),
    /// online first, then by name.
    public static func visible(_ machines: [Machine], now: Date = .now) -> [Machine] {
        machines.filter { $0.revokedAt == nil && $0.replacedByMachineId == nil }
            .sorted {
                let lhs = $0.isOnline(at: now), rhs = $1.isOnline(at: now)
                if lhs != rhs { return lhs }
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
    }

    // MARK: Renaming (`machine-update-metadata`)

    /// The whole metadata with the new name; an empty name goes back to the host name.
    public func renamedMetadata(_ name: String) -> JSONValue {
        var document = metadata.objectValue ?? [:]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        document["displayName"] = trimmed.isEmpty ? nil : .string(trimmed)
        return .object(document)
    }

    /// Metadata as the relay stores it for this machine: sealed with its key, or base64 of
    /// `{"t":"plain","v":…}` (`machineStoredContent.ts`).
    public func encodeMetadata(_ document: JSONValue) throws -> String {
        if let cipher { return try cipher.encryptBase64(document) }
        return try JSONValue.object(["t": "plain", "v": document]).encoded().base64EncodedString()
    }

    /// The relay's answer to a metadata write, newer than what this copy has.
    mutating func apply(metadata value: JSONValue?, version: Int) throws {
        guard version > metadataVersion else { return }
        metadata = try decode(value) ?? metadata
        metadataVersion = version
    }

    // MARK: Realtime

    /// An `update-machine` body: newer documents, and whatever status fields it carries.
    public mutating func apply(update body: JSONValue) throws {
        if let m = body["metadata"], let version = m["version"]?.intValue { try apply(metadata: m["value"], version: version) }
        if let d = body["daemonState"], let version = d["version"]?.intValue, version > daemonStateVersion {
            daemon = Daemon(try decode(d["value"]))
            daemonStateVersion = version
        }
        if let value = body["active"]?.boolValue { active = value }
        if body["activeAt"] != nil { activeAt = Session.date(body["activeAt"]) ?? activeAt }
        if let value = body["revokedAt"] {
            revokedAt = Self.positiveDate(value)
            if revokedAt != nil { active = false }
        }
        if let value = body["replacedByMachineId"] { replacedByMachineId = value.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
    }

    /// A `machine-activity` heartbeat.
    public mutating func apply(activity payload: JSONValue) {
        if let value = payload["active"]?.boolValue { active = value }
        if let date = Session.date(payload["activeAt"]) { activeAt = date }
    }

    // MARK: Helpers

    /// Folders of this machine's sessions, most recent first (no duplicates).
    public static func recentDirectories(machineId: String, sessions: [Session]) -> [String] {
        var seen = Set<String>()
        return sessions.filter { $0.machineId == machineId }
            .sorted { $0.sortDate > $1.sortDate }
            .compactMap(\.path)
            .filter { seen.insert($0).inserted }
    }

    /// `dataEncryptionKey` = base64 of `{"t":"plain","v":null}` (`machineStoredContent.ts`).
    static func isPlainMarker(_ key: String?) -> Bool {
        key.flatMap(Base64.decode).flatMap { try? JSONValue.parse($0) }?["t"]?.stringValue == "plain"
    }

    private static func plainDocument(_ base64: String?) -> JSONValue? {
        guard let doc = base64.flatMap(Base64.decode).flatMap({ try? JSONValue.parse($0) }), doc["t"]?.stringValue == "plain" else { return nil }
        return doc["v"]
    }

    /// A stored document (metadata, daemon state) in this machine's format; nil when absent.
    private func decode(_ value: JSONValue?) throws -> JSONValue? {
        guard let base64 = value?.stringValue else { return nil }
        if let cipher { return try cipher.decryptBase64(base64) }
        return Self.plainDocument(base64)
    }

    private static func positiveDate(_ value: JSONValue?) -> Date? {
        guard let ms = value?.doubleValue, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}

/// What `capabilities.detect` found on a machine (`capabilitiesProtocol.ts`): each agent's CLI
/// and tmux. Nil from a CLI too old to answer.
public struct DetectedTools: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case installed(version: String?, path: String?)
        case missing
        /// The check failed on the machine.
        case unknown
    }

    public struct AgentCLI: Sendable, Equatable, Identifiable {
        public let id: String
        public let state: State
    }

    /// In catalog order (`Agent.ids`).
    public let agents: [AgentCLI]
    public let tmux: State?

    public init?(response: JSONValue) {
        guard let results = response["results"]?.objectValue else { return nil }
        var found: [String: State] = [:]
        for (key, result) in results where key.hasPrefix("cli.") {
            let id = Agent.id(fromFlavor: String(key.dropFirst(4))) ?? String(key.dropFirst(4))
            found[id] = Self.state(result, agentVersion: true)
        }
        agents = Agent.ids.compactMap { id in found[id].map { AgentCLI(id: id, state: $0) } }
        tmux = results["tool.tmux"].map { Self.state($0, agentVersion: false) }
    }

    private static func state(_ result: JSONValue, agentVersion: Bool) -> State {
        guard result["ok"]?.boolValue == true, let data = result["data"] else { return .unknown }
        guard data["available"]?.boolValue == true else { return data["available"]?.boolValue == false ? .missing : .unknown }
        let raw = data["version"]?.stringValue
        let version = agentVersion ? raw.map(semver) : raw
        return .installed(version: version, path: data["resolvedPath"]?.stringValue)
    }

    /// `2.1.3 (Claude Code)` → `2.1.3`; text without a version stays as it is.
    private static func semver(_ text: String) -> String {
        guard let range = text.range(of: #"\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?"#, options: .regularExpression) else { return text }
        return String(text[range])
    }
}

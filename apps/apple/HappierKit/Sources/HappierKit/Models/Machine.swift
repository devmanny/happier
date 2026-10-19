import Foundation

/// A computer running the Happier daemon (`GET /v1/machines`).
public struct Machine: Identifiable, Sendable, Equatable {
    public struct Undecryptable: Error {}

    public let id: String
    public let active: Bool
    public let activeAt: Date?
    public let metadata: JSONValue
    /// Content cipher for machine RPC; nil for plain machines.
    let cipher: ContentCipher?

    public static func == (lhs: Machine, rhs: Machine) -> Bool {
        lhs.id == rhs.id && lhs.active == rhs.active && lhs.activeAt == rhs.activeAt && lhs.metadata == rhs.metadata
    }

    public init(row: JSONValue, keys: AccountKeys?) throws {
        guard let id = row["id"]?.stringValue else { throw Undecryptable() }
        self.id = id
        active = row["active"]?.boolValue ?? false
        activeAt = Session.date(row["activeAt"])
        let key = row["dataEncryptionKey"]?.stringValue
        if Self.isPlainMarker(key) {
            cipher = nil
            metadata = Self.plainDocument(row["metadata"]?.stringValue) ?? [:]
        } else {
            guard let resolved = keys?.cipher(forDataEncryptionKey: key) else { throw Undecryptable() }
            cipher = resolved
            metadata = try row["metadata"]?.stringValue.map { try resolved.decryptBase64($0) } ?? [:]
        }
    }

    public var name: String { metadata["displayName"]?.stringValue ?? metadata["host"]?.stringValue ?? id }
    public var homeDir: String? { metadata["homeDir"]?.stringValue }
    public var platform: String? { metadata["platform"]?.stringValue }
    public var cliVersion: String? { metadata["happyCliVersion"]?.stringValue }

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
}

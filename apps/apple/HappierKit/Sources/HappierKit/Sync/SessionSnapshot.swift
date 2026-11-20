import Foundation

/// The session list as last synced: the server's rows, still encrypted, and the account change
/// cursor (`/v2/cursor`) they reflect. Kept on disk so the list shows at launch before the network
/// answers, and brought up to date with only the sessions changed since (`/v2/changes`).
public struct SessionSnapshot: Sendable, Equatable {
    public var rows: [JSONValue]
    public var cursor: Int?

    public init(rows: [JSONValue], cursor: Int?) {
        self.rows = rows
        self.cursor = cursor
    }

    /// The snapshot after the changes since `cursor`: changed rows replace or join the list, and
    /// archived or deleted sessions leave it, as they do the server's list (`/v2/sessions`).
    public func applying(changed: [String: JSONValue], removed: Set<String>, cursor: Int) -> SessionSnapshot {
        func keeps(_ row: JSONValue) -> Bool {
            guard let id = row["id"]?.stringValue, !removed.contains(id) else { return false }
            return row["archivedAt"].map { $0.isNull } ?? true
        }
        var seen = Set<String>()
        var next: [JSONValue] = rows.map { row in
            guard let id = row["id"]?.stringValue else { return row }
            seen.insert(id)
            return changed[id] ?? row
        }
        next += changed.filter { !seen.contains($0.key) }.map(\.value)
        return SessionSnapshot(rows: next.filter(keeps), cursor: cursor)
    }
}

/// One file per relay and account in Caches: the system may purge it, and the next sync rebuilds it.
public actor SessionSnapshotStore {
    private let url: URL

    public init(directory: URL, scope: String) {
        let name = scope.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }
        url = directory.appending(path: "sessions-\(String(name)).json")
    }

    public func load() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: url), let root = try? JSONValue.parse(data),
              root["v"]?.intValue == 1, let rows = root["rows"]?.arrayValue else { return nil }
        return SessionSnapshot(rows: rows, cursor: root["cursor"]?.intValue)
    }

    public func save(_ snapshot: SessionSnapshot) {
        let root: JSONValue = ["v": 1, "cursor": snapshot.cursor.map { .number(Double($0)) } ?? .null, "rows": .array(snapshot.rows)]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try root.encoded().write(to: url, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A `/v2/changes` page, reduced to what the session list needs.
public enum SessionChanges {
    public struct Page: Equatable, Sendable {
        public let sessionIds: [String]
        public let nextCursor: Int?
        /// Entries of every kind, to tell a full page from the last one.
        public let count: Int
    }

    public static func page(_ response: JSONValue) -> Page {
        let changes = response["changes"]?.arrayValue ?? []
        var seen = Set<String>()
        let ids = changes.compactMap { change -> String? in
            guard change["kind"]?.stringValue == "session", let id = change["entityId"]?.stringValue, seen.insert(id).inserted else { return nil }
            return id
        }
        return Page(sessionIds: ids, nextCursor: response["nextCursor"]?.intValue, count: changes.count)
    }
}

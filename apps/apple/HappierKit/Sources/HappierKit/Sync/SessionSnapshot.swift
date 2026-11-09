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

    /// Archived sessions leave the list, as they do the server's.
    static func isListed(_ row: JSONValue) -> Bool {
        row["archivedAt"].map { $0.isNull } ?? true
    }

    /// The snapshot after the changes since `cursor`: changed rows replace or join the list, and
    /// archived or deleted sessions leave it, as they do the server's list (`/v2/sessions`).
    public func applying(changed: [String: JSONValue], removed: Set<String>, cursor: Int) -> SessionSnapshot {
        func keeps(_ row: JSONValue) -> Bool {
            guard let id = row["id"]?.stringValue, !removed.contains(id) else { return false }
            return Self.isListed(row)
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

/// One folder per relay and account in Caches (the system may purge it; the next sync rebuilds it),
/// with one file per session row and a cursor file. A sync writes only the sessions whose rows
/// changed (a real row is ~20 KB of encrypted metadata; the whole list is megabytes, and every
/// reconnect syncs), then the cursor: cut off in between, the old cursor stays and the next sync
/// fetches those changes again. Each file is written atomically.
public actor SessionSnapshotStore {
    private let folder: URL
    private let cursorURL: URL
    /// The single-file list of earlier versions, removed on the first write.
    private let legacyURL: URL

    public init(directory: URL, scope: String) {
        let name = String(scope.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        folder = directory.appending(path: "sessions-\(name)", directoryHint: .isDirectory)
        cursorURL = folder.appending(path: "cursor.json")
        legacyURL = directory.appending(path: "sessions-\(name).json")
    }

    public func load() -> SessionSnapshot? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return nil }
        let rows = files.filter { $0.pathExtension == "row" }.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONValue.parse($0) }
        }
        let cursor = (try? Data(contentsOf: cursorURL)).flatMap { try? JSONValue.parse($0) }
        guard !rows.isEmpty || cursor != nil else { return nil }
        // Without a cursor the rows still show at launch; the next sync is a full one.
        return SessionSnapshot(rows: rows, cursor: cursor?["cursor"]?.intValue)
    }

    /// The whole list (a full sync): the rows that differ from what's stored, then the cursor.
    public func save(_ snapshot: SessionSnapshot) {
        let listed = Set(snapshot.rows.compactMap { $0["id"]?.stringValue })
        let stored = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let gone = stored.filter { $0.pathExtension == "row" && !listed.contains($0.deletingPathExtension().lastPathComponent) }
        write(rows: snapshot.rows, removing: gone, cursor: snapshot.cursor)
    }

    /// A changed-only sync: changed rows replace or join, archived or deleted sessions leave.
    public func apply(changed: [String: JSONValue], removed: Set<String>, cursor: Int) {
        guard FileManager.default.fileExists(atPath: cursorURL.path) else { return }
        let leaving = changed.filter { !SessionSnapshot.isListed($0.value) }.map(\.key)
        write(rows: changed.filter { !leaving.contains($0.key) }.map(\.value),
              removing: (removed.union(leaving)).map(rowURL), cursor: cursor)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: legacyURL)
    }

    private func write(rows: [JSONValue], removing gone: [URL], cursor: Int?) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for row in rows {
                guard let id = row["id"]?.stringValue else { continue }
                let url = rowURL(id)
                // Compared as values: the encoding's key order isn't stable.
                if (try? Data(contentsOf: url)).flatMap({ try? JSONValue.parse($0) }) != row {
                    try row.encoded().write(to: url, options: .atomic)
                }
            }
            for url in gone { try? FileManager.default.removeItem(at: url) }
            let root: JSONValue = ["v": 1, "cursor": cursor.map { .number(Double($0)) } ?? .null]
            try root.encoded().write(to: cursorURL, options: .atomic)
            try? FileManager.default.removeItem(at: legacyURL)
        } catch {
            clear()
        }
    }

    private func rowURL(_ id: String) -> URL {
        folder.appending(path: String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }) + ".row")
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

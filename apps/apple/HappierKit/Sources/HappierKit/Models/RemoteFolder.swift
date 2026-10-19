import Foundation

/// A folder on a daemon machine, from `daemon.filesystem.listRoots` / `listDirectory`.
public struct RemoteFolder: Identifiable, Hashable, Sendable {
    public struct ListingError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public var id: String { path }
    public let name: String
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }

    public var isHidden: Bool { name.hasPrefix(".") }

    /// Directories of a `listDirectory` response: visible ones A→Z, hidden ones last.
    public static func listing(from response: JSONValue) throws -> (folders: [RemoteFolder], truncated: Bool) {
        guard response["ok"]?.boolValue == true else {
            throw ListingError(message: response["error"]?.stringValue ?? String(localized: "This folder can't be opened."))
        }
        let folders = (response["entries"]?.arrayValue ?? [])
            .filter { $0["type"]?.stringValue == "directory" }
            .compactMap { entry -> RemoteFolder? in
                guard let name = entry["name"]?.stringValue, let path = entry["path"]?.stringValue else { return nil }
                return RemoteFolder(name: name, path: path)
            }
            .sorted { ($0.isHidden ? 1 : 0, $0.name.lowercased()) < ($1.isHidden ? 1 : 0, $1.name.lowercased()) }
        return (folders, response["truncated"]?.boolValue ?? false)
    }

    /// Child path using the machine's separator (`machine.metadata.platform`).
    public static func join(_ parent: String, _ name: String, platform: String?) -> String {
        let separator: Character = platform == "win32" ? "\\" : "/"
        var base = parent
        while base.count > 1, base.last == separator { base.removeLast() }
        return base + String(separator) + name
    }
}

import Foundation

/// What the share extension hands the app: files (voice memos, photos, documents) and a message
/// for one conversation, kept in the App Group until the app takes them and sends them with its
/// own send. The extension never holds account keys or talks to the relay.
public struct ShareOutbox: Sendable {
    public struct Delivery: Equatable, Sendable {
        public let id: String
        public let sessionId: String
        public let message: String
        public let files: [URL]
        public let createdAt: Date
    }

    private struct Manifest: Codable {
        let sessionId: String
        let message: String
        let files: [String]
        let createdAt: Date
    }

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The App Group's outbox, shared by the app and its share extension.
    public static var shared: ShareOutbox? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AttentionSnapshot.appGroup)
            .map { ShareOutbox(root: $0.appendingPathComponent("ShareOutbox", isDirectory: true)) }
    }

    /// Copies `files` in and records them for `sessionId`; the manifest is written last, so a
    /// delivery only appears once all its files are there.
    public func add(sessionId: String, message: String, files: [URL]) throws {
        let id = UUID().uuidString
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var names: [String] = []
        for (index, file) in files.enumerated() {
            // A numbered folder each, so two "IMG.jpg" from different places both survive and
            // keep the name the agent will see.
            let slot = folder.appendingPathComponent(String(index), isDirectory: true)
            try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: file, to: slot.appendingPathComponent(file.lastPathComponent))
            names.append("\(index)/\(file.lastPathComponent)")
        }
        let manifest = Manifest(sessionId: sessionId, message: message, files: names, createdAt: .now)
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
    }

    /// Deliveries waiting, oldest first.
    public func pending() -> [Delivery] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder -> Delivery? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
            return Delivery(id: folder.lastPathComponent, sessionId: manifest.sessionId, message: manifest.message,
                            files: manifest.files.map { folder.appendingPathComponent($0) }, createdAt: manifest.createdAt)
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    public func remove(_ delivery: Delivery) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(delivery.id, isDirectory: true))
    }
}

/// The conversations the share extension offers, newest first, as the app last saw them.
public struct ShareTargets: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable, Identifiable {
        public let sessionId: String
        public let title: String
        public let agentId: String?
        /// The project folder's name.
        public let folder: String?
        public let date: Date
        public var id: String { sessionId }
    }

    public let items: [Item]
    private static let key = "happier.shareTargets.v1"

    /// `sessions` in the order the app lists them.
    public init(sessions: [Session], limit: Int = 100) {
        items = sessions.prefix(limit).map { session in
            Item(sessionId: session.id, title: session.title, agentId: session.agentId,
                 folder: session.path.flatMap { $0.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) },
                 date: session.updatedAt)
        }
    }

    public static func load(from defaults: UserDefaults? = UserDefaults(suiteName: AttentionSnapshot.appGroup)) -> ShareTargets? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ShareTargets.self, from: data)
    }

    public func save(to defaults: UserDefaults? = UserDefaults(suiteName: AttentionSnapshot.appGroup)) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults?.set(data, forKey: Self.key)
    }
}

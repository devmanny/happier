import Foundation

/// The sessions waiting on you, as the Home Screen and lock screen widgets show them. The app
/// writes it to the App Group it shares with the widget, which can't reach the relay or decrypt
/// sessions itself; each item opens its session through the app's own session link.
public struct AttentionSnapshot: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        /// The agent stopped for an approval or an answer.
        case waitingForYou
        /// It finished or said something you haven't read.
        case unread
    }

    /// The approval or answer the agent stopped for, as the watch offers to allow or deny it.
    public struct Request: Codable, Equatable, Sendable {
        public let id: String
        public let tool: String
        /// "Bash: git push", "Edit: Main.swift", the question asked.
        public let summary: String

        public init(id: String, tool: String, summary: String) {
            self.id = id
            self.tool = tool
            self.summary = summary
        }
    }

    public struct Item: Codable, Equatable, Sendable, Identifiable {
        public let sessionId: String
        public let title: String
        public let agentId: String?
        public let reason: Reason
        public let date: Date
        public let link: URL?
        /// The first pending request, when waiting for you (added for the watch; older snapshots lack it).
        public let request: Request?
        /// The agent's last words, shortened (when the app had the conversation at hand).
        public let lastAgentText: String?
        public var id: String { sessionId }

        public init(sessionId: String, title: String, agentId: String?, reason: Reason, date: Date, link: URL?,
                    request: Request? = nil, lastAgentText: String? = nil) {
            self.sessionId = sessionId
            self.title = title
            self.agentId = agentId
            self.reason = reason
            self.date = date
            self.link = link
            self.request = request
            self.lastAgentText = lastAgentText
        }
    }

    /// Everything waiting, including what doesn't fit in `items`.
    public let total: Int
    public let items: [Item]
    public let updatedAt: Date

    /// The App Group shared with the widget extension (team-prefixed on the Mac, where a sandboxed
    /// Developer ID app can use it without a provisioning profile entry).
    public static var appGroup: String {
        #if os(macOS)
        "DPF7ZLTLN2.com.devmanny.happier"
        #else
        "group.com.devmanny.happier"
        #endif
    }

    private static let key = "happier.attention.v1"

    public init(total: Int, items: [Item], updatedAt: Date) {
        self.total = total
        self.items = items
        self.updatedAt = updatedAt
    }

    /// `excerpts`: each session's last agent text, where known (`Transcript.lastAgentText`).
    public init(sessions: [Session], server: URL, limit: Int, excerpts: [String: String] = [:], now: Date = .now) {
        let waiting: [Item] = sessions.compactMap { session in
            let requests = Transcript.pendingRequests(from: session.agentState)
            let reason: Reason
            let date: Date
            var request: Request?
            if let first = requests.first {
                reason = .waitingForYou
                date = first.createdAt ?? session.updatedAt
                request = Request(id: first.id, tool: first.tool, summary: first.summary)
            } else if let unread = session.unreadSince {
                reason = .unread
                date = max(unread, session.updatedAt)
            } else {
                return nil
            }
            return Item(sessionId: session.id, title: session.title, agentId: session.agentId, reason: reason, date: date,
                        link: SessionLink(sessionId: session.id, server: server)?.nativeURL,
                        request: request, lastAgentText: excerpts[session.id].flatMap(Self.excerpt))
        }
        let ordered = waiting.sorted { a, b in
            if (a.reason == .waitingForYou) != (b.reason == .waitingForYou) { return a.reason == .waitingForYou }
            return a.date > b.date
        }
        total = ordered.count
        items = Array(ordered.prefix(limit))
        updatedAt = now
    }

    public static func load(from defaults: UserDefaults? = UserDefaults(suiteName: appGroup)) -> AttentionSnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(AttentionSnapshot.self, from: data)
    }

    public func save(to defaults: UserDefaults? = UserDefaults(suiteName: appGroup)) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults?.set(data, forKey: Self.key)
    }

    /// One line of at most 400 characters, as the watch shows it.
    static func excerpt(_ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        return String(words.joined(separator: " ").prefix(400))
    }

    /// Whether showing `other` instead would change anything on screen (the time it was taken aside).
    public func looksLike(_ other: AttentionSnapshot?) -> Bool {
        guard let other else { return false }
        return total == other.total && items == other.items
    }
}

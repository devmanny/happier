import Foundation

/// What the "Working Now", "Recent" and "Usage" widgets show, left by the app in the App Group
/// (like `AttentionSnapshot`): the sessions working, the latest ones with the state the session
/// list gives them, and the tightest limit of each provider as last read.
public struct ActivitySnapshot: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case working, waiting, unread, failed, idle, offline
    }

    public struct Item: Codable, Equatable, Sendable, Identifiable {
        public let sessionId: String
        public let title: String
        public let agentId: String?
        public let folder: String?
        public let state: State
        /// When it started working (for a timer), else its last activity.
        public let since: Date
        public let link: URL?
        /// A stopped session the idle cleaner put to rest (`Session.isResting`). Kept apart from
        /// `state`, which stays `offline`: the watch decodes the whole snapshot with that enum, and a
        /// watch app older than resting would drop every update carrying a new case.
        private let resting: Bool?
        public var id: String { sessionId }
        public var isResting: Bool { resting == true }

        public init(sessionId: String, title: String, agentId: String?, folder: String?, state: State, since: Date, link: URL?,
                    resting: Bool = false) {
            self.sessionId = sessionId
            self.title = title
            self.agentId = agentId
            self.folder = folder
            self.state = state
            self.since = since
            self.link = link
            self.resting = resting ? true : nil
        }
    }

    public struct Usage: Codable, Equatable, Sendable, Identifiable {
        public let providerId: String
        public let plan: String?
        /// The meter closest to its limit ("weekly", "five_hour").
        public let meter: String
        public let usedPercent: Double
        public let resetsAt: Date?
        public let fetchedAt: Date?
        public var id: String { providerId }

        public init(providerId: String, plan: String?, meter: String, usedPercent: Double, resetsAt: Date?, fetchedAt: Date?) {
            self.providerId = providerId
            self.plan = plan
            self.meter = meter
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
            self.fetchedAt = fetchedAt
        }
    }

    public let working: [Item]
    public let recent: [Item]
    public let usage: [Usage]
    public let updatedAt: Date

    private static let key = "happier.activity.v1"

    /// `sessions` in the order the app lists them.
    public init(sessions: [Session], usage readings: [ProviderUsage], server: URL, now: Date = .now) {
        let items = sessions.map { Self.item($0, server: server, now: now) }
        working = items.filter { $0.state == .working }.sorted { $0.since < $1.since }
        recent = Array(items.prefix(8))
        var newest: [String: ProviderUsage] = [:]
        for reading in readings {
            guard let provider = reading.providerId else { continue }
            if let kept = newest[provider], (kept.fetchedAt ?? .distantPast) >= (reading.fetchedAt ?? .distantPast) { continue }
            newest[provider] = reading
        }
        usage = newest.keys.sorted().compactMap { provider in
            // The chat's ring: the tightest account-wide limit; a model's own limit only when
            // that's all there is.
            guard let reading = newest[provider],
                  let meter = reading.mostConstrained(modelId: nil)
                    ?? reading.meters.filter(\.isLimit).max(by: { $0.usedPercent < $1.usedPercent }) else { return nil }
            return Usage(providerId: provider, plan: reading.planLabel, meter: meter.label, usedPercent: meter.usedPercent,
                         resetsAt: meter.resetsAt, fetchedAt: reading.fetchedAt)
        }
        updatedAt = now
    }

    public init(working: [Item], recent: [Item], usage: [Usage], updatedAt: Date) {
        self.working = working
        self.recent = recent
        self.usage = usage
        self.updatedAt = updatedAt
    }

    private static func item(_ session: Session, server: URL, now: Date) -> Item {
        let state: State
        switch session.status(at: now) {
        case .permissionRequired, .actionRequired: state = .waiting
        case .working: state = .working
        case .failed: state = .failed
        case .offline: state = .offline
        case .idle: state = session.unreadSince != nil ? .unread : .idle
        }
        let since = state == .working ? (session.thinkingAt ?? session.activeAt ?? session.sortDate) : session.sortDate
        return Item(sessionId: session.id, title: session.title, agentId: session.agentId,
                    folder: session.path.flatMap { $0.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) },
                    state: state, since: since, link: SessionLink(sessionId: session.id, server: server)?.nativeURL,
                    resting: state == .offline && session.isResting)
    }

    public static func load(from defaults: UserDefaults? = UserDefaults(suiteName: AttentionSnapshot.appGroup)) -> ActivitySnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ActivitySnapshot.self, from: data)
    }

    public func save(to defaults: UserDefaults? = UserDefaults(suiteName: AttentionSnapshot.appGroup)) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults?.set(data, forKey: Self.key)
    }

    /// Whether showing `other` instead would change anything on screen.
    public func looksLike(_ other: ActivitySnapshot?) -> Bool {
        guard let other else { return false }
        return working == other.working && recent == other.recent && usage == other.usage
    }
}

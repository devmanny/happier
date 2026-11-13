import Foundation

/// Which sessions the list shows: their kind, state, agent, provider and model, and optionally only
/// those that need you. Stored on the device (JSON); the default is the usual list (running, resting and stopped
/// sessions, archive apart) without the sessions tasks started.
public struct SessionListFilter: Equatable, Sendable, Codable {
    /// Every session has exactly one kind; a sub-session a task started counts as a task session.
    public enum Kind: String, CaseIterable, Sendable, Codable, Identifiable {
        case normal
        /// Started by a task or one of its repeats (`threads`, `occurrences`; a scheduled start
        /// records its session in `threads`).
        case task
        /// Started from inside another session.
        case sub

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .normal: String(localized: "Normal sessions")
            case .task: String(localized: "Task sessions")
            case .sub: String(localized: "Sub-sessions")
            }
        }
    }

    public enum State: String, CaseIterable, Sendable, Codable, Identifiable {
        /// `inactive` is every session not running and not archived, resting or stopped (the stored
        /// raw value stays as it was).
        case active, inactive, archived

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .active: String(localized: "Active")
            case .inactive: String(localized: "Resting & Stopped")
            case .archived: String(localized: "Archived")
            }
        }
    }

    public enum AgentChoice: Hashable, Sendable, Codable {
        case all
        /// Sessions that don't work as one of your agents.
        case none
        case agent(String)
    }

    public var kinds: Set<Kind>
    public var states: Set<State>
    /// Only sessions waiting for you, unread, or with open tasks.
    public var attentionOnly: Bool
    public var agent: AgentChoice
    /// Only sessions of this provider (the agent's id: "claude", "codex"…).
    public var provider: String?
    /// Only sessions running a model of this family (`RunningModel.word`: "Opus").
    public var modelFamily: String?
    /// Only sessions running exactly this model (`RunningModel.id`); narrows `modelFamily`.
    public var modelId: String?

    public init(kinds: Set<Kind>, states: Set<State>, attentionOnly: Bool = false, agent: AgentChoice = .all,
                provider: String? = nil, modelFamily: String? = nil, modelId: String? = nil) {
        self.kinds = kinds
        self.states = states
        self.attentionOnly = attentionOnly
        self.agent = agent
        self.provider = provider
        self.modelFamily = modelFamily
        self.modelId = modelId
    }

    public static let `default` = SessionListFilter(kinds: [.normal, .sub], states: [.active, .inactive])
    public static let all = SessionListFilter(kinds: Set(Kind.allCases), states: Set(State.allCases))
    public static let waitingForMe = SessionListFilter(kinds: Set(Kind.allCases), states: [.active, .inactive], attentionOnly: true)
    public static let activeWithoutTasks = SessionListFilter(kinds: [.normal, .sub], states: [.active])

    public struct Shortcut: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let filter: SessionListFilter
    }

    public static var shortcuts: [Shortcut] {
        [
            Shortcut(id: "all", title: String(localized: "All sessions"), filter: .all),
            Shortcut(id: "waiting", title: String(localized: "Waiting for me"), filter: .waitingForMe),
            Shortcut(id: "active", title: String(localized: "Active without tasks"), filter: .activeWithoutTasks),
        ]
    }

    public var isDefault: Bool { self == .default }
    /// The archive isn't part of the synced list; showing it means fetching it.
    public var includesArchived: Bool { states.contains(.archived) }

    /// What the tasks say about the sessions, computed once per list.
    public struct Context: Sendable {
        let taskSessionIds: Set<String>
        let openTaskSessionIds: Set<String>

        public init(tasks: [AgentTask]) {
            var started: Set<String> = []
            var open: Set<String> = []
            for task in tasks {
                for link in task.linkedSessions {
                    if link.reasons.contains(.worked) || link.reasons.contains(.occurrence) { started.insert(link.sessionId) }
                    if task.isOpen { open.insert(link.sessionId) }
                }
            }
            taskSessionIds = started
            openTaskSessionIds = open
        }

        public func kind(of session: Session) -> Kind {
            if taskSessionIds.contains(session.id) { return .task }
            return session.parentSessionId == nil ? .normal : .sub
        }

        public func needsAttention(_ session: Session, now: Date = .now) -> Bool {
            switch session.status(at: now) {
            case .permissionRequired, .actionRequired: return true
            default: return session.unreadSince != nil || openTaskSessionIds.contains(session.id)
            }
        }
    }

    public static func state(of session: Session) -> State {
        if session.archivedAt != nil { return .archived }
        return session.active ? .active : .inactive
    }

    public func includes(_ session: Session, context: Context, now: Date = .now) -> Bool {
        guard kinds.contains(context.kind(of: session)), states.contains(Self.state(of: session)) else { return false }
        switch agent {
        case .all: break
        case .none: if session.agentIdentity != nil { return false }
        case .agent(let id): if session.agentIdentity?.id != id { return false }
        }
        if let provider, session.agentId != provider { return false }
        if modelId != nil || modelFamily != nil {
            guard let model = session.runningModel else { return false }
            if let modelId {
                if model.id != modelId { return false }
            } else if model.word != modelFamily {
                return false
            }
        }
        return !attentionOnly || context.needsAttention(session, now: now)
    }

    /// "Task sessions · Active · Mateo": what differs from the usual list, or the shortcut's name;
    /// nil for the usual list.
    public func summary(agentName: (String) -> String?) -> String? {
        guard !isDefault else { return nil }
        if let shortcut = Self.shortcuts.first(where: { $0.filter == self }) { return shortcut.title }
        var parts: [String] = []
        if kinds != Self.default.kinds { parts.append(Kind.allCases.filter(kinds.contains).map(\.label).joined(separator: ", ")) }
        if states != Self.default.states { parts.append(State.allCases.filter(states.contains).map(\.label).joined(separator: ", ")) }
        if attentionOnly { parts.append(String(localized: "Needs me")) }
        switch agent {
        case .all: break
        case .none: parts.append(String(localized: "No agent"))
        case .agent(let id): parts.append(agentName(id) ?? String(localized: "An agent"))
        }
        if let provider { parts.append(Agent.displayNames[provider] ?? provider) }
        if let model = modelId.map(RunningModel.name(for:)) ?? modelFamily { parts.append(model) }
        return parts.joined(separator: " · ")
    }

    // MARK: Providers and models to choose from

    /// What the filter offers: the providers the sessions run on and their models, by family.
    public struct ModelOptions: Equatable, Sendable {
        public struct Model: Identifiable, Equatable, Sendable {
            public let id: String
            public let name: String
        }

        public struct Family: Identifiable, Equatable, Sendable {
            public let provider: String
            public let word: String
            /// Newest first.
            public let models: [Model]
            public var id: String { provider + "/" + word }
        }

        /// Agent ids, ordered by their name.
        public let providers: [String]
        public let families: [Family]

        public init(sessions: [Session]) {
            var providers: Set<String> = []
            // Provider, family, model id: the model's name.
            var names: [String: [String: [String: String]]] = [:]
            for session in sessions {
                guard let provider = session.agentId else { continue }
                providers.insert(provider)
                guard let model = session.runningModel else { continue }
                let known = names[provider]?[model.word]?[model.id]
                guard known == nil || known == model.id else { continue }
                var name = RunningModel.name(for: model.id)
                // A model the catalog doesn't know goes by the name a session lists it with.
                if name == model.id {
                    name = SessionControls(metadata: session.metadata, agentId: provider).models
                        .first { RunningModel.normalized($0.id) == model.id }?.name ?? model.id
                }
                names[provider, default: [:]][model.word, default: [:]][model.id] = name
            }
            func name(_ provider: String) -> String { Agent.displayNames[provider] ?? provider }
            self.providers = providers.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
            families = self.providers.flatMap { provider in
                (names[provider] ?? [:]).sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map { word, models in
                    Family(provider: provider, word: word, models: models.map { Model(id: $0.key, name: $0.value) }
                        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending })
                }
            }
        }

        public func families(for provider: String?) -> [Family] {
            provider.map { provider in families.filter { $0.provider == provider } } ?? families
        }
    }

    // MARK: Storage

    /// Kept in the device's settings as JSON; anything unreadable is the default.
    public init(stored: String) {
        self = (try? JSONDecoder().decode(Self.self, from: Data(stored.utf8))) ?? .default
    }

    public var stored: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

/// The list's filter button: a tap switches between the usual list and the chosen filter; holding
/// it opens the chosen filter to change it. Stored on the device, under the key the plain filter
/// used before (read here as a chosen filter that is on).
public struct SessionListFilterChoice: Equatable, Sendable, Codable {
    /// What a tap brings; the usual list until a filter is chosen (then a tap opens the filter).
    public private(set) var chosen: SessionListFilter
    public private(set) var isOn: Bool

    /// The filter the list shows.
    public var applied: SessionListFilter { isOn ? chosen : .default }

    /// A filter other than the usual list is chosen, on or off: the button carries a dot.
    public var hasChosenFilter: Bool { !chosen.isDefault }

    /// Switches the chosen filter on or off; false when nothing is chosen (then the filter opens).
    @discardableResult
    public mutating func toggle() -> Bool {
        guard !chosen.isDefault else { return false }
        isOn.toggle()
        return true
    }

    /// A filter picked or edited: it shows at once.
    public mutating func choose(_ filter: SessionListFilter) {
        chosen = filter
        isOn = !filter.isDefault
    }

    /// Back to the usual list, the chosen filter kept for the next tap.
    public mutating func clear() { isOn = false }

    public init(stored: String) {
        let data = Data(stored.utf8)
        if let choice = try? JSONDecoder().decode(Self.self, from: data) {
            self = choice
        } else if let filter = try? JSONDecoder().decode(SessionListFilter.self, from: data), !filter.isDefault {
            chosen = filter
            isOn = true
        } else {
            chosen = .default
            isOn = false
        }
    }

    public var stored: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

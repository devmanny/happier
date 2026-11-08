import Foundation

/// Permission intents offered by the composer (`packages/agents/src/types.ts`, `permissionModeOptions.ts`).
public enum PermissionMode: String, CaseIterable, Sendable {
    case `default` = "default"
    case readOnly = "read-only"
    case safeYolo = "safe-yolo"
    case yolo = "yolo"

    /// Canonicalizes stored values, including provider-native aliases.
    init(stored: String?) {
        switch stored?.lowercased() {
        case "read-only", "plan": self = .readOnly
        case "safe-yolo", "acceptedits", "auto": self = .safeYolo
        case "yolo", "bypasspermissions": self = .yolo
        default: self = .default
        }
    }

    /// Providers whose `default` mode asks before changes; elsewhere it defers to the CLI's own settings.
    private static func asks(_ agentId: String?) -> Bool { agentId == "claude" || agentId == "gemini" }

    public func label(agentId: String?) -> String {
        switch self {
        case .default: Self.asks(agentId) ? "Ask" : "CLI Settings"
        case .readOnly: "Read Only"
        case .safeYolo: agentId == "gemini" ? "Safe YOLO" : "Auto"
        case .yolo: "YOLO"
        }
    }

    /// The mode's SF Symbol, decided with its name: one family (circled outlines). `default` reads
    /// "Ask" (a question) where it asks, and "CLI Settings" (an empty circle) elsewhere.
    public func symbolName(agentId: String?) -> String {
        switch self {
        case .readOnly: "eye.circle"
        case .default: Self.asks(agentId) ? "questionmark.circle" : "circle"
        case .safeYolo: "bolt.circle"
        case .yolo: "checkmark.circle"
        }
    }
}

public struct ModelChoice: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let effortLevels: [String]
    public let defaultEffort: String?
    public let supportsUltracode: Bool
    /// Context window size, when the agent reports it with its models.
    public var contextWindowTokens: Int? = nil
}

public struct SlashCommand: Identifiable, Equatable, Sendable {
    public var id: String { command }
    public let command: String
    public let description: String?
}

/// Read model of the composer controls for one session's metadata.
public struct SessionControls: Equatable, Sendable {
    public let agentId: String?
    /// Selectable models, excluding the "Use CLI settings" (`default`) entry.
    public let models: [ModelChoice]
    /// `"default"` when no override is set.
    public let selectedModelId: String
    /// Model the runtime reports as applied (`sessionAppliedModelV1`).
    public let appliedModelId: String?
    /// The concrete model the runtime says it is on (`currentModelId`), e.g. what an alias like
    /// "opus" resolved to.
    public let currentModelId: String?
    public let effort: String?
    public let ultracode: Bool?
    public let permissionMode: PermissionMode
    public let slashCommands: [SlashCommand]

    public init(metadata: JSONValue, agentId: String?) {
        self.agentId = agentId
        let provider = Self.providerMatches(agentId: agentId)

        let state = Self.newest(metadata, "sessionModelsV1", "acpSessionModelsV1")
            .flatMap { state in provider(state["provider"]?.stringValue) && (state["updatedAt"]?.doubleValue ?? 0) > 0 ? state : nil }
        let dynamic = state?["availableModels"]?.arrayValue?.compactMap { Self.dynamicModel($0, agentId: agentId) }
        models = dynamic ?? (agentId == "claude" ? ClaudeCatalog.models : [])
        currentModelId = state?["currentModelId"]?.stringValue

        let override = metadata["modelOverrideV1"]
        selectedModelId = override?["modelId"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "default"

        let applied = metadata["sessionAppliedModelV1"]
        appliedModelId = provider(applied?["provider"]?.stringValue) ? applied?["modelId"]?.stringValue : nil

        let overrides = Self.newest(metadata, "sessionConfigOptionOverridesV1", "acpConfigOptionOverridesV1")?["overrides"]
        effort = overrides?["reasoning_effort"]?["value"]?.stringValue?.lowercased()
        ultracode = switch overrides?["ultracode"]?["value"] {
        case .bool(let b)?: b
        case .string(let s)?: s.lowercased() == "true" ? true : (s.lowercased() == "false" ? false : nil)
        default: nil
        }

        permissionMode = PermissionMode(stored: metadata["permissionMode"]?.stringValue)

        var commands: [SlashCommand] = []
        if let details = metadata["slashCommandDetails"]?.arrayValue, !details.isEmpty {
            commands = details.compactMap { d in d["command"]?.stringValue.map { SlashCommand(command: $0, description: d["description"]?.stringValue) } }
        } else {
            commands = (metadata["slashCommands"]?.arrayValue ?? []).compactMap { $0.stringValue.map { SlashCommand(command: $0, description: nil) } }
        }
        for builtIn in ["compact", "clear"] where !commands.contains(where: { $0.command == builtIn }) {
            commands.append(SlashCommand(command: builtIn, description: nil))
        }
        slashCommands = commands
    }

    public var selectedModel: ModelChoice? { models.first { $0.id == selectedModelId } }

    /// The model whose effort levels apply: the selection, else what the runtime reports. A Claude
    /// model missing from the list the session reported is still known from the catalog.
    public var effortModel: ModelChoice? {
        func lookup(_ id: String) -> ModelChoice? {
            models.first { $0.id == id } ?? (agentId == "claude" ? ClaudeCatalog.models.first { $0.id == id } : nil)
        }
        let chosen = (selectedModelId == "default" ? nil : lookup(selectedModelId)) ?? appliedModelId.flatMap(lookup)
        // An alias ("opus", "default") carries no effort of its own; the model it runs as does.
        if chosen?.effortLevels.isEmpty ?? true, let current = currentModelId.flatMap(lookup), !current.effortLevels.isEmpty {
            return current
        }
        return chosen
    }

    /// The effort on the model pill: the chosen level, else the model's default. A model without
    /// effort levels shows none; an unknown model still shows the level that was chosen.
    public var displayEffort: String? {
        guard let model = effortModel else { return effort }
        guard !model.effortLevels.isEmpty else { return nil }
        return effort ?? model.defaultEffort
    }

    /// Models to offer when starting a new session of `agentId`: what that agent last reported in
    /// your most recent session with it (the list is only known once a runtime has started), else
    /// the built-in catalog (Claude).
    public static func newSessionModels(agentId: String, sessions: [Session]) -> [ModelChoice] {
        let latest = sessions.filter { $0.agentId == agentId }.sorted { $0.sortDate > $1.sortDate }
        for session in latest {
            let models = SessionControls(metadata: session.metadata, agentId: agentId).models
            if !models.isEmpty { return models }
        }
        return SessionControls(metadata: .object([:]), agentId: agentId).models
    }

    /// Fields merged into the outgoing user message `meta` (`outgoingUserMessage.ts`,
    /// `buildClaudeSessionComposerNextMessageMetaOverrides.ts`).
    public var messageMeta: JSONValue {
        var meta: [String: JSONValue] = ["permissionMode": .string(permissionMode.rawValue)]
        if selectedModelId != "default" { meta["model"] = .string(selectedModelId) }
        if agentId == "claude" {
            if let effort { meta["reasoningEffort"] = .string(effort) }
            if let ultracode { meta["ultracode"] = .bool(ultracode) }
        }
        return .object(meta)
    }

    // MARK: Helpers

    /// Canonical vs legacy alias: newest `updatedAt` wins, canonical wins ties (`metadataKeys.ts`).
    static func newest(_ metadata: JSONValue, _ canonical: String, _ legacy: String) -> JSONValue? {
        let a = metadata[canonical].flatMap { $0.isNull ? JSONValue?.none : $0 }
        let b = metadata[legacy].flatMap { $0.isNull ? JSONValue?.none : $0 }
        guard let a else { return b }
        guard let b else { return a }
        return (b["updatedAt"]?.doubleValue ?? 0) > (a["updatedAt"]?.doubleValue ?? 0) ? b : a
    }

    private static func providerMatches(agentId: String?) -> (String?) -> Bool {
        { provider in
            guard let provider, let agentId else { return false }
            return provider == agentId || (agentId == "customAcp" && provider.hasPrefix("acp:"))
        }
    }

    private static func dynamicModel(_ raw: JSONValue, agentId: String?) -> ModelChoice? {
        guard let id = raw["id"]?.stringValue, let name = raw["name"]?.stringValue else { return nil }
        let options = raw["modelOptions"]?.arrayValue ?? []
        let effortOption = options.first { $0["id"]?.stringValue == "reasoning_effort" }
        var levels = effortOption?["options"]?.arrayValue?.compactMap { $0["value"]?.stringValue } ?? []
        var defaultEffort = effortOption?["currentValue"]?.stringValue
        var ultracode = options.contains { $0["id"]?.stringValue == "ultracode" }
        // Some Claude runtimes report the list without `modelOptions`; the catalog knows the levels.
        if agentId == "claude", options.isEmpty, let known = ClaudeCatalog.models.first(where: { $0.id == id }) {
            levels = known.effortLevels
            defaultEffort = known.defaultEffort
            ultracode = known.supportsUltracode
        }
        return ModelChoice(
            id: id, name: name, description: raw["description"]?.stringValue ?? ClaudeCatalog.description(for: id),
            effortLevels: levels, defaultEffort: defaultEffort,
            supportsUltracode: ultracode,
            contextWindowTokens: raw["contextWindowTokens"]?.doubleValue.flatMap { $0 > 0 ? Int($0) : nil })
    }

    // MARK: Context window (`resolveContextWarningWindowTokens.ts`, `providers/claude/contextWindow.ts`)

    static let claudeDefaultWindow = 200_000
    static let claudeLargeWindow = 1_000_000
    /// Claude models that always run with the 1M window.
    static let claudeAlwaysLargeWindow: Set<String> = [
        "claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-opus-5", "claude-sonnet-5", "claude-fable-5",
        "claude-opus-4-8", "claude-opus-4-7",
    ]

    /// The window the context ring measures against: what the agent reported, else the active
    /// model's, else Claude's known sizes (bumped to 1M when the usage already exceeds 200K).
    /// Nil when unknown, as for most non-Claude agents that don't report one.
    public func contextWindow(for usage: ContextUsage) -> Int? {
        if let reported = usage.reportedWindowTokens, reported > 0 { return reported }
        let activeId = selectedModelId != "default" ? selectedModelId : appliedModelId
        if let id = activeId, let window = models.first(where: { $0.id == id })?.contextWindowTokens { return window }
        guard agentId == "claude" else { return nil }
        var window = Self.claudeDefaultWindow
        if let id = activeId?.lowercased() {
            let base = id.replacingOccurrences(of: #"\[[^\]]*\]$"#, with: "", options: .regularExpression)
            if id.hasSuffix("[1m]") || Self.claudeAlwaysLargeWindow.contains(base) { window = Self.claudeLargeWindow }
        }
        if usage.usedTokens > window { window = max(Self.claudeLargeWindow, usage.usedTokens) }
        return window
    }
}

/// Pure metadata transforms for the composer controls (`packages/agents/src/sessionControls/publish.ts`).
public enum MetadataEdit {
    /// `modelOverrideV1` with force_update semantics; `"default"` selects CLI settings.
    public static func setModel(_ modelId: String, in metadata: JSONValue, now: Double) -> JSONValue {
        let previous = metadata["modelOverrideV1"]?["updatedAt"]?.doubleValue ?? 0
        return set(metadata, "modelOverrideV1", ["v": 1, "updatedAt": .number(max(now, previous + 1)), "modelId": .string(modelId)])
    }

    /// `permissionMode` + `permissionModeUpdatedAt`, ignoring writes older than the stored one.
    public static func setPermissionMode(_ mode: PermissionMode, in metadata: JSONValue, now: Double) -> JSONValue {
        guard now > (metadata["permissionModeUpdatedAt"]?.doubleValue ?? 0) else { return metadata }
        var edited = set(metadata, "permissionMode", .string(mode.rawValue))
        edited = set(edited, "permissionModeUpdatedAt", .number(now))
        return edited
    }

    /// Merges one option into `sessionConfigOptionOverridesV1` and its legacy alias.
    public static func setConfigOption(_ id: String, value: JSONValue, in metadata: JSONValue, now: Double) -> JSONValue {
        let base = SessionControls.newest(metadata, "sessionConfigOptionOverridesV1", "acpConfigOptionOverridesV1")
        var overrides = base?["overrides"]?.objectValue ?? [:]
        if let existing = overrides[id]?["updatedAt"]?.doubleValue, existing >= now { return metadata }
        overrides[id] = ["updatedAt": .number(now), "value": value]
        let root: JSONValue = ["v": 1, "updatedAt": .number(max(now, base?["updatedAt"]?.doubleValue ?? 0)), "overrides": .object(overrides)]
        return set(set(metadata, "sessionConfigOptionOverridesV1", root), "acpConfigOptionOverridesV1", root)
    }

    /// Moves the session under another one in the session list, or to its top level (nil). Only the
    /// apps read it; who started the session (`spawnedBySessionV1`) stays as it was.
    public static func setListParent(_ parentSessionId: String?, in metadata: JSONValue, now: Double) -> JSONValue {
        set(metadata, "listParentV1", ["v": 1, "updatedAt": .number(now), "parentSessionId": parentSessionId.map(JSONValue.string) ?? .null])
    }

    /// The session's bell: off (`muted`) means it never notifies; it still talks to its parent.
    public static func setNotificationsMuted(_ muted: Bool, in metadata: JSONValue, now: Double) -> JSONValue {
        set(metadata, "notificationsMutedV1", ["v": 1, "muted": .bool(muted), "updatedAt": .number(now)])
    }

    /// The session's title (`summary`, as the agent's own title updates write it).
    public static func setTitle(_ title: String, in metadata: JSONValue, now: Double) -> JSONValue {
        set(metadata, "summary", ["text": .string(title), "updatedAt": .number(now)])
    }

    private static func set(_ metadata: JSONValue, _ key: String, _ value: JSONValue) -> JSONValue {
        var object = metadata.objectValue ?? [:]
        object[key] = value
        return .object(object)
    }
}

/// Static Claude catalog for sessions without a dynamic model list (`packages/agents/src/models.ts`,
/// `providers/claude/effort.ts`).
enum ClaudeCatalog {
    private static let full = ["low", "medium", "high", "xhigh", "max"]

    static let models: [ModelChoice] = [
        model("claude-fable-5-1", "Fable 5.1", full, "For your hardest challenges"),
        model("claude-opus-5-5", "Opus 5.5", full, "For complex work and everyday tasks", defaultEffort: "medium"),
        model("claude-sonnet-5-5", "Sonnet 5.5", full, "More efficient for simpler tasks"),
        model("claude-opus-5", "Opus 5", full),
        model("claude-sonnet-5", "Sonnet 5", full),
        model("claude-fable-5", "Fable 5", full),
        model("claude-opus-4-8", "Opus 4.8", full),
        model("claude-opus-4-7", "Opus 4.7", full, defaultEffort: "xhigh"),
        model("claude-opus-4-6", "Opus 4.6", ["low", "medium", "high", "max"]),
        model("claude-sonnet-4-6", "Sonnet 4.6", ["low", "medium", "high"]),
        model("claude-haiku-4-5", "Haiku 4.5", []),
        model("claude-opus-4-5", "Opus 4.5", ["low", "medium", "high"]),
        model("claude-sonnet-4-5", "Sonnet 4.5", []),
    ]

    static func description(for id: String) -> String? { models.first { $0.id == id }?.description }

    private static func model(_ id: String, _ name: String, _ levels: [String], _ description: String? = nil, defaultEffort: String = "high") -> ModelChoice {
        ModelChoice(id: id, name: name, description: description, effortLevels: levels,
                    defaultEffort: levels.isEmpty ? nil : defaultEffort, supportsUltracode: levels.contains("xhigh"))
    }
}

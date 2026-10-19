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

    public func label(agentId: String?) -> String {
        switch self {
        case .default: (agentId == "claude" || agentId == "gemini") ? "Default" : "CLI Settings"
        case .readOnly: "Read Only"
        case .safeYolo: agentId == "gemini" ? "Safe YOLO" : "Auto"
        case .yolo: "YOLO"
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
    public let effort: String?
    public let ultracode: Bool?
    public let permissionMode: PermissionMode
    public let slashCommands: [SlashCommand]

    public init(metadata: JSONValue, agentId: String?) {
        self.agentId = agentId
        let provider = Self.providerMatches(agentId: agentId)

        let dynamic = Self.newest(metadata, "sessionModelsV1", "acpSessionModelsV1")
            .flatMap { state -> [ModelChoice]? in
                guard provider(state["provider"]?.stringValue), (state["updatedAt"]?.doubleValue ?? 0) > 0 else { return nil }
                return state["availableModels"]?.arrayValue?.compactMap(Self.dynamicModel)
            }
        models = dynamic ?? (agentId == "claude" ? ClaudeCatalog.models : [])

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
        let a = metadata[canonical].flatMap { $0.isNull ? nil : $0 }
        let b = metadata[legacy].flatMap { $0.isNull ? nil : $0 }
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

    private static func dynamicModel(_ raw: JSONValue) -> ModelChoice? {
        guard let id = raw["id"]?.stringValue, let name = raw["name"]?.stringValue else { return nil }
        let options = raw["modelOptions"]?.arrayValue ?? []
        let effortOption = options.first { $0["id"]?.stringValue == "reasoning_effort" }
        let levels = effortOption?["options"]?.arrayValue?.compactMap { $0["value"]?.stringValue } ?? []
        return ModelChoice(
            id: id, name: name, description: raw["description"]?.stringValue ?? ClaudeCatalog.description(for: id),
            effortLevels: levels, defaultEffort: effortOption?["currentValue"]?.stringValue,
            supportsUltracode: options.contains { $0["id"]?.stringValue == "ultracode" })
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

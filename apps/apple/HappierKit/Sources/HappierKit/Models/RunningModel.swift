import Foundation

/// The model a session runs on, as the session list shows it (one word on the row) and filters by
/// it: `id` is the model's id without its variant suffix, `word` its family ("Opus", "Sol", "K3.1").
public struct RunningModel: Hashable, Sendable {
    public let id: String
    public let word: String

    public init(id: String, word: String) {
        self.id = id
        self.word = word
    }

    /// What the session runs on: the chosen model, else the one the runtime applied, else the one it
    /// says it is on. An alias ("opus") is known by the model it runs as when the runtime reports
    /// one of the same family. Nil while nothing names a model ("Use CLI settings" on a session
    /// whose runtime hasn't reported yet).
    init?(metadata: JSONValue, agentId: String?) {
        let provider = SessionControls.providerMatches(agentId: agentId)
        let applied = metadata["sessionAppliedModelV1"]
        let state = SessionControls.newest(metadata, "sessionModelsV1", "acpSessionModelsV1")
            .flatMap { provider($0["provider"]?.stringValue) && ($0["updatedAt"]?.doubleValue ?? 0) > 0 ? $0 : nil }
        let named = [
            metadata["modelOverrideV1"]?["modelId"]?.stringValue,
            provider(applied?["provider"]?.stringValue) ? applied?["modelId"]?.stringValue : nil,
            state?["currentModelId"]?.stringValue,
        ].compactMap { raw -> RunningModel? in
            guard let raw, let word = Self.word(for: raw) else { return nil }
            return RunningModel(id: Self.normalized(raw), word: word)
        }
        guard let chosen = named.first else { return nil }
        self = chosen.isConcrete ? chosen : named.first { $0.word == chosen.word && $0.isConcrete } ?? chosen
    }

    /// A versioned model ("claude-opus-5-5"), not an alias ("opus").
    private var isConcrete: Bool { id.contains(where: \.isNumber) }

    /// One word for a model: "claude-fable-5-2" is "Fable", "gpt-6.1-sol" is "Sol",
    /// "kimi-code/k3.1-pro" is "K3.1". A model with no word of its own goes by its vendor and
    /// version ("GPT-5"). Nil for what names no model ("default").
    public static func word(for modelId: String) -> String? {
        let id = normalized(modelId)
        guard !id.isEmpty, id != "default" else { return nil }
        let tokens = (id.split(separator: "/").last ?? "").split(whereSeparator: { "-_ :".contains($0) }).map(String.init)
        if let word = tokens.first(where: { !vendors.contains($0) && !isVersion($0) && !qualifiers.contains($0) }) {
            return word.prefix(1).uppercased() + word.dropFirst()
        }
        guard let vendor = tokens.first(where: vendors.contains) else { return tokens.first }
        let name = vendor.count <= 3 ? vendor.uppercased() : vendor.prefix(1).uppercased() + vendor.dropFirst()
        return [name, tokens.first(where: isVersion)].compactMap { $0 }.joined(separator: "-")
    }

    /// The model's name: Claude's as the catalog has them ("Opus 5.5"), an alias by its word, any
    /// other by its id.
    public static func name(for modelId: String) -> String {
        let id = normalized(modelId)
        if let known = ClaudeCatalog.models.first(where: { $0.id == id }) { return known.name }
        return id.contains(where: \.isNumber) ? id : word(for: id) ?? id
    }

    /// Lowercased, without the variant suffix ("opus[1m]" is "opus").
    static func normalized(_ modelId: String) -> String {
        modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: #"\[[^\]]*\]$"#, with: "", options: .regularExpression)
    }

    private static let vendors: Set<String> = ["claude", "gpt", "chatgpt", "openai", "anthropic", "kimi", "moonshot", "gemini", "google"]
    private static let qualifiers: Set<String> = ["latest", "preview", "exp", "experimental"]

    private static func isVersion(_ token: String) -> Bool {
        token.range(of: #"^v?\d[\d.]*$"#, options: .regularExpression) != nil
    }
}

extension Session {
    public var runningModel: RunningModel? { RunningModel(metadata: metadata, agentId: agentId) }
}

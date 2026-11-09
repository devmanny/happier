import Foundation

/// Claude Code's slash-command bookkeeping rows (`<command-name>`, `<local-command-stdout>`, ...):
/// written to its transcript when a command runs, forwarded by older CLIs or typed in the
/// terminal. They are a compact system line (`local-command` event, `data.text`), never the
/// user's bubble: the caveat is hidden, `/model` and `/effort` show only their result, by name.
enum LocalCommandLine {
    static let kind = "local-command"

    /// Nil when `text` isn't a command row; empty when the row is hidden.
    static func blocks(for text: String) -> [Normalizer.Block]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<local-command-caveat>") { return [] }
        // Built-ins start with the name, skill commands with the message; either way it's one row.
        if ["<command-name>", "<command-message>", "<command-args>"].contains(where: trimmed.hasPrefix) {
            guard let name = tag("command-name", in: trimmed)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
            // Their stdout says what was set.
            if ["/model", "/effort"].contains(name.lowercased()) { return [] }
            let args = tag("command-args", in: trimmed)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return [line(args.isEmpty ? name : "\(name) \(args)")]
        }
        for output in ["local-command-stdout", "local-command-stderr"] where trimmed.hasPrefix("<\(output)>") {
            let body = (tag(output, in: trimmed) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = body.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) else { return [] }
            if let model = modelSet(first) { return [line(String(localized: "Model: \(model.name)"), ["model": .string(model.id ?? model.name)])] }
            if let effort = effortSet(first) {
                return [line(String(localized: "Effort: \(effort.capitalized)"), ["effort": .string(effort.lowercased())])]
            }
            return [line(first)]
        }
        return nil
    }

    /// Whether a model or effort line repeats a runner change line (`runtime-config-outcome`).
    static func repeats(_ line: JSONValue, outcome: JSONValue) -> Bool {
        let changes = outcome["changes"]?.arrayValue ?? []
        func effective(_ key: String) -> String? { changes.first { $0["key"]?.stringValue == key }?["effective"]?.stringValue?.lowercased() }
        if let model = line["model"]?.stringValue?.lowercased(), let changed = effective("model") {
            return changed == model || ClaudeCatalog.models.first { $0.id == changed }?.name.lowercased() == model
        }
        if let effort = line["effort"]?.stringValue, let changed = effective("reasoningEffort") { return changed == effort }
        return false
    }

    private static func line(_ text: String, _ extra: [String: JSONValue] = [:]) -> Normalizer.Block {
        .event(kind: kind, data: .object(extra.merging(["text": .string(text)]) { $1 }))
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"), let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }

    /// "Set model to claude-opus-5-5", "Set model to `opus (claude-opus-5-5)`",
    /// "Set model to `Fable 5.1` for this session only".
    private static func modelSet(_ text: String) -> (id: String?, name: String)? {
        guard text.hasPrefix("Set model to ") else { return nil }
        var value = String(text.dropFirst("Set model to ".count))
        if let range = value.range(of: " for this session only") { value.removeSubrange(range) }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "` ."))
        if let match = value.firstMatch(of: /claude-[a-z0-9-]+/) {
            let id = String(match.output)
            return (id, ClaudeCatalog.models.first { $0.id == id }?.name ?? id)
        }
        if let known = ClaudeCatalog.models.first(where: { $0.name.caseInsensitiveCompare(value) == .orderedSame }) { return (known.id, known.name) }
        return value.isEmpty ? nil : (nil, value)
    }

    /// "Set effort level to high (this session only): ...".
    private static func effortSet(_ text: String) -> String? {
        guard text.hasPrefix("Set effort level to ") else { return nil }
        return text.dropFirst("Set effort level to ".count).split(whereSeparator: { $0 == " " || $0 == ":" }).first.map(String.init)
    }
}

import Foundation

/// Agent catalog subset needed for display (`packages/agents/src/manifest.ts`, `resolveAgentIdFromFlavor.ts`).
public enum Agent {
    public static let ids = [
        "claude", "codex", "opencode", "gemini", "auggie", "qwen", "kimi", "kilo", "kiro", "devin",
        "customAcp", "pi", "copilot", "cursor", "grok", "agy", "fx", "droid", "codebuddy",
    ]

    private static let aliases: [String: String] = [
        "codex-acp": "codex", "codex-mcp": "codex", "openai": "codex", "gpt": "codex",
        "open-code": "opencode", "qwen-code": "qwen", "kimi-cli": "kimi", "kilocode": "kilo",
        "kiro-cli": "kiro", "devin-cli": "devin", "custom-acp": "customAcp", "pi-coding-agent": "pi",
        "github-copilot": "copilot", "copilot-cli": "copilot", "cursor-agent": "cursor",
        "grok-build": "grok", "grok-cli": "grok", "factory-droid": "droid", "codebuddy-code": "codebuddy",
    ]

    public static let displayNames: [String: String] = [
        "claude": "Claude Code", "codex": "Codex", "opencode": "OpenCode", "gemini": "Gemini",
        "auggie": "Auggie", "qwen": "Qwen Code", "kimi": "Kimi", "kilo": "Kilo Code", "kiro": "Kiro",
        "devin": "Devin", "customAcp": "ACP Agent", "pi": "Pi", "copilot": "Copilot", "cursor": "Cursor",
        "grok": "Grok", "agy": "Antigravity", "fx": "fx", "droid": "Droid", "codebuddy": "CodeBuddy",
    ]

    /// The agents a machine has installed, from its `capabilities.detect` response (`cli.<agent>`
    /// results with `available: true`); nil when the response isn't one.
    public static func installed(fromDetect response: JSONValue) -> Set<String>? {
        guard let results = response["results"]?.objectValue else { return nil }
        var agents = Set<String>()
        for (key, result) in results where key.hasPrefix("cli.") {
            guard result["ok"]?.boolValue == true, result["data"]?["available"]?.boolValue == true else { continue }
            agents.insert(id(fromFlavor: String(key.dropFirst(4))) ?? String(key.dropFirst(4)))
        }
        return agents
    }

    public static func id(fromFlavor flavor: String?) -> String? {
        guard let normalized = flavor?.trimmingCharacters(in: .whitespaces).lowercased(), !normalized.isEmpty else { return nil }
        if normalized.hasPrefix("acp:") { return "customAcp" }
        return ids.first { $0.lowercased() == normalized } ?? aliases[normalized]
    }
}

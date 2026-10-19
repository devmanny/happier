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

    public static func id(fromFlavor flavor: String?) -> String? {
        guard let normalized = flavor?.trimmingCharacters(in: .whitespaces).lowercased(), !normalized.isEmpty else { return nil }
        if normalized.hasPrefix("acp:") { return "customAcp" }
        return ids.first { $0.lowercased() == normalized } ?? aliases[normalized]
    }
}

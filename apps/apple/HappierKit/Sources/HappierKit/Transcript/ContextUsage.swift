import Foundation

/// How full the agent's context is, from the token counts it writes into the transcript
/// (`reducer.processUsageData`, `typesRaw/tokenCountUsage.ts`): Claude's `usage` on each answer,
/// Codex/ACP `token_count` rows. A compaction or context reset empties it.
public struct ContextUsage: Equatable, Sendable {
    public var usedTokens: Int
    /// The window size, when the agent reports it (Codex, some ACP agents).
    public var reportedWindowTokens: Int?

    public init(usedTokens: Int, reportedWindowTokens: Int?) {
        self.usedTokens = usedTokens
        self.reportedWindowTokens = reportedWindowTokens
    }

    /// The latest usage across records ordered oldest to newest, or nil when none reports any.
    /// The usage after `records`, continuing from `starting` (the usage before them).
    public static func latest(in records: some Sequence<JSONValue>, startingFrom starting: ContextUsage? = nil) -> ContextUsage? {
        var current = starting
        for record in records {
            switch reading(record) {
            case .usage(let used, let derived, let window)?:
                let size = used ?? (window != nil ? current?.usedTokens ?? 0 : derived)
                current = ContextUsage(usedTokens: size, reportedWindowTokens: window ?? current?.reportedWindowTokens)
            case .reset?:
                current = ContextUsage(usedTokens: 0, reportedWindowTokens: current?.reportedWindowTokens)
            case nil:
                continue
            }
        }
        return current
    }

    private enum Reading {
        /// `used`: the size the agent reports; `derived`: input plus cached input.
        case usage(used: Int?, derived: Int, window: Int?)
        case reset
    }

    private static func reading(_ record: JSONValue) -> Reading? {
        guard record["role"]?.stringValue == "agent", record["meta"]?["sidechainId"]?.stringValue == nil,
              let content = record["content"] else { return nil }
        let data = content["data"] ?? .null
        switch content["type"]?.stringValue {
        case "output":
            guard data["type"]?.stringValue == "assistant", let usage = data["message"]?["usage"],
                  let input = number(usage, ["input_tokens"]) else { return nil }
            let cached = (number(usage, ["cache_creation_input_tokens"]) ?? 0) + (number(usage, ["cache_read_input_tokens"]) ?? 0)
            return .usage(used: number(usage, ["context_used_tokens"]), derived: input + cached,
                          window: number(usage, ["context_window_tokens"]))
        case "event":
            let message = data["type"]?.stringValue == "message" ? data["message"]?.stringValue : nil
            return message == "Context was reset" || message == "Compaction completed" ? .reset : nil
        case "codex", "acp":
            if data["type"]?.stringValue == "context-compaction" {
                return data["phase"]?.stringValue == "completed" ? .reset : nil
            }
            guard data["type"]?.stringValue == "token_count" else { return nil }
            return tokenCount(data)
        default:
            return nil
        }
    }

    private static let usedKeys = ["context_used_tokens", "contextUsedTokens", "used"]
    private static let windowKeys = ["context_window_tokens", "contextWindowTokens", "contextWindow", "context_window", "size"]

    private static func tokenCount(_ data: JSONValue) -> Reading? {
        let nested = data["tokens"].flatMap { $0.objectValue != nil ? $0 : nil }
        guard let counts = nested.flatMap(tokenRecord) ?? tokenRecord(data) else { return nil }
        let used = number(data, usedKeys) ?? nested.flatMap { number($0, usedKeys) }
        let window = number(data, windowKeys) ?? nested.flatMap { number($0, windowKeys) }
        return .usage(used: used, derived: counts, window: window)
    }

    /// Input plus cached input of a token record, nil when it has no counts at all.
    private static func tokenRecord(_ record: JSONValue) -> Int? {
        let input = number(record, ["input", "input_tokens", "prompt_tokens"]) ?? number(record, ["used"])
        let output = number(record, ["output", "output_tokens", "completion_tokens"])
        let cacheRead = number(record, ["cache_read", "cache_read_input_tokens", "cached_read"])
        let cacheCreation = number(record, ["cache_creation", "cache_creation_input_tokens", "cache_write", "cached_write"])
        guard input != nil || output != nil || cacheRead != nil || cacheCreation != nil else { return nil }
        return (input ?? 0) + (cacheRead ?? 0) + (cacheCreation ?? 0)
    }

    private static func number(_ record: JSONValue, _ keys: [String]) -> Int? {
        for key in keys {
            if let value = record[key]?.doubleValue, value.isFinite, value >= 0 { return Int(value) }
        }
        return nil
    }
}

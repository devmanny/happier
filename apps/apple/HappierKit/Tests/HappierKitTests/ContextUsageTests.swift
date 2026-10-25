import Foundation
import Testing
@testable import HappierKit

@Suite struct ContextUsageTests {
    private func claude(_ usage: JSONValue) -> JSONValue {
        ["role": "agent", "content": ["type": "output", "data": ["type": "assistant", "message": ["role": "assistant", "content": [], "usage": usage]]]]
    }

    private func tokenCount(_ provider: String, _ data: JSONValue) -> JSONValue {
        guard case .object(var fields) = data else { return .null }
        fields["type"] = "token_count"
        return ["role": "agent", "content": ["type": .string(provider), "data": .object(fields)]]
    }

    private let compacted: JSONValue = ["role": "agent", "content": ["type": "event", "data": ["type": "message", "message": "Compaction completed"]]]

    @Test func claudeCountsInputPlusCacheAndTheNewestWins() {
        let usage = ContextUsage.latest(in: [
            claude(["input_tokens": 10, "output_tokens": 5]),
            claude(["input_tokens": 3, "output_tokens": 50, "cache_creation_input_tokens": 1_000, "cache_read_input_tokens": 60_000]),
        ])
        #expect(usage == ContextUsage(usedTokens: 61_003, reportedWindowTokens: nil))
    }

    @Test func tokenCountsReportUsedAndWindow() {
        let usage = ContextUsage.latest(in: [
            tokenCount("codex", ["used": 1_200, "size": 258_400, "tokens": ["input": 700, "output": 250, "cache_read": 200]]),
        ])
        #expect(usage == ContextUsage(usedTokens: 1_200, reportedWindowTokens: 258_400))
        let acp = ContextUsage.latest(in: [tokenCount("acp", ["tokens": ["input": 700, "cache_read": 300, "output": 9]])])
        #expect(acp == ContextUsage(usedTokens: 1_000, reportedWindowTokens: nil))
    }

    @Test func compactionEmptiesTheContextButKeepsTheWindow() {
        let usage = ContextUsage.latest(in: [
            tokenCount("codex", ["used": 90_000, "size": 258_400, "tokens": ["input": 90_000]]),
            compacted,
        ])
        #expect(usage == ContextUsage(usedTokens: 0, reportedWindowTokens: 258_400))
    }

    @Test func sidechainsAndRowsWithoutCountsAreIgnored() {
        var sidechain = claude(["input_tokens": 999_999])
        if case .object(var fields) = sidechain { fields["meta"] = ["sidechainId": "task-1"]; sidechain = .object(fields) }
        #expect(ContextUsage.latest(in: [claude(["input_tokens": 100]), sidechain]) == ContextUsage(usedTokens: 100, reportedWindowTokens: nil))
        #expect(ContextUsage.latest(in: [["role": "user", "content": ["type": "text", "text": "hi"]]]) == nil)
    }

    @Test func windowFollowsReportThenModelThenClaudeSizes() {
        let used = ContextUsage(usedTokens: 50_000, reportedWindowTokens: nil)
        func controls(_ agent: String, model: String?, models: [JSONValue] = []) -> SessionControls {
            var metadata: [String: JSONValue] = [:]
            if let model { metadata["modelOverrideV1"] = ["v": 1, "updatedAt": 1, "modelId": .string(model)] }
            if !models.isEmpty {
                metadata["sessionModelsV1"] = ["v": 1, "provider": .string(agent), "updatedAt": 1, "availableModels": .array(models)]
            }
            return SessionControls(metadata: .object(metadata), agentId: agent)
        }
        #expect(controls("codex", model: nil).contextWindow(for: ContextUsage(usedTokens: 1, reportedWindowTokens: 258_400)) == 258_400)
        #expect(controls("opencode", model: "m1", models: [["id": "m1", "name": "M1", "contextWindowTokens": 128_000]]).contextWindow(for: used) == 128_000)
        #expect(controls("claude", model: "claude-opus-5-5").contextWindow(for: used) == 1_000_000)
        #expect(controls("claude", model: "claude-sonnet-4-5[1m]").contextWindow(for: used) == 1_000_000)
        #expect(controls("claude", model: "claude-sonnet-4-5").contextWindow(for: used) == 200_000)
        #expect(controls("claude", model: "claude-sonnet-4-5").contextWindow(for: ContextUsage(usedTokens: 250_000, reportedWindowTokens: nil)) == 1_000_000)
        #expect(controls("opencode", model: nil).contextWindow(for: used) == nil)
    }
}

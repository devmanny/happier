import Foundation
import Testing
@testable import HappierKit

@Suite struct SubagentTests {
    private func row(_ seq: Int, _ data: JSONValue, sidechain: String? = nil) -> TranscriptMessage {
        TranscriptMessage(id: "m\(seq)", seq: seq, localId: nil, createdAt: Date(timeIntervalSince1970: Double(seq)),
                          record: ["role": "agent", "content": ["type": "output", "data": data]], sidechainId: sidechain)
    }

    private func launch(_ seq: Int, id: String, name: String = "Agent") -> TranscriptMessage {
        row(seq, ["type": "assistant", "message": ["role": "assistant", "content": [
            ["type": "tool_use", "id": .string(id), "name": .string(name),
             "input": ["description": "Trace the composer", "subagent_type": "Explore", "prompt": "Find it"]],
        ]]])
    }

    private func result(_ seq: Int, id: String, _ text: String, error: Bool = false) -> TranscriptMessage {
        row(seq, ["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": .string(id), "is_error": .bool(error), "content": [["type": "text", "text": .string(text)]]],
        ]]])
    }

    private func sidechainReply(_ seq: Int, of id: String, _ text: String, final: Bool) -> TranscriptMessage {
        row(seq, ["type": "assistant", "isSidechain": true, "agentId": "a1", "message": [
            "role": "assistant", "stop_reason": final ? "end_turn" : .null,
            "content": final ? [["type": "text", "text": .string(text)]] : [["type": "tool_use", "id": "t9", "name": "Read", "input": [:]]],
        ]], sidechain: id)
    }

    @Test func backgroundAgentsRunUntilTheirOwnThreadEnds() {
        var transcript = Transcript()
        transcript.apply([launch(1, id: "toolu_1"), result(2, id: "toolu_1", "Async agent launched successfully.\nagentId: a1")])
        #expect(transcript.subagents.map(\.status) == [.running])
        #expect(transcript.subagents.first?.title == "Trace the composer")
        #expect(transcript.subagents.first?.kind == "Explore")

        transcript.apply([sidechainReply(3, of: "toolu_1", "", final: false)])
        #expect(transcript.subagents.first?.status == .running)
        #expect(transcript.subagents.first?.lastActivityAt == Date(timeIntervalSince1970: 3))

        transcript.apply([sidechainReply(4, of: "toolu_1", "Here is what I found", final: true)])
        #expect(transcript.subagents.first?.status == .finished)
        // The subagent's own thread stays out of the main conversation.
        #expect(!transcript.items.contains { if case .agentText(let text) = $0 { text.text == "Here is what I found" } else { false } })
    }

    @Test func foregroundAgentsFollowTheirToolCall() {
        var transcript = Transcript()
        transcript.apply([launch(1, id: "a"), launch(2, id: "b", name: "Task"), launch(3, id: "c")])
        #expect(transcript.subagents.map(\.status) == [.running, .running, .running])
        transcript.apply([result(4, id: "a", "All done"), result(5, id: "b", "boom", error: true)])
        #expect(transcript.subagents.map(\.status) == [.finished, .failed, .running])
    }

    @Test func aSidechainTranscriptShowsTheSubagentsOwnWork() {
        var thread = Transcript(sidechain: true)
        thread.apply([
            row(10, ["type": "user", "isSidechain": true, "message": ["role": "user", "content": [["type": "text", "text": "Find it"]]]], sidechain: "toolu_1"),
            sidechainReply(11, of: "toolu_1", "", final: false),
            sidechainReply(12, of: "toolu_1", "Here is what I found", final: true),
        ])
        let kinds = thread.items.map { item -> String in
            switch item {
            case .userText(let text): "user:\(text.text)"
            case .agentText(let text): "agent:\(text.text)"
            case .toolCall(let tool): "tool:\(tool.name)"
            default: "other"
            }
        }
        #expect(kinds == ["user:Find it", "tool:Read", "agent:Here is what I found"])
    }
}

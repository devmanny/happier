import Foundation
import Testing
@testable import HappierKit

/// Behavior mirrors `apps/ui/sources/sync/typesRaw/normalize.ts` + `apps/ui/sources/sync/reducer/**`.
@Suite struct TranscriptTests {
    private func raw(_ id: String, _ seq: Int, _ record: JSONValue, localId: String? = nil) -> TranscriptMessage {
        TranscriptMessage(id: id, seq: seq, localId: localId, createdAt: Date(timeIntervalSince1970: Double(seq)), record: record)
    }

    private func agentOutput(_ data: JSONValue) -> JSONValue { ["role": "agent", "content": ["type": "output", "data": data]] }
    private func assistant(_ blocks: JSONValue) -> JSONValue { agentOutput(["type": "assistant", "message": ["role": "assistant", "content": blocks]]) }

    @Test func reducesRealClaudeTraceToMainTranscript() throws {
        // The repo fixture used by the TS reducer tests (UI app owns it; read in place).
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "../../ui/sources/sync/__testdata__/trace_0.json").standardized
        let rows = try JSONValue.parse(Data(contentsOf: url)).arrayValue ?? []
        var transcript = Transcript()
        transcript.apply(rows.map { row in
            raw(row["id"]!.stringValue!, row["seq"]!.intValue!, row["content"]!, localId: row["localId"]?.stringValue)
        })
        let items = transcript.items
        let firstUserText: String? = if case .userText(let u)? = items.first { u.text } else { nil }
        #expect(firstUserText == "Run few test tasks using Task tool")
        let tools = items.compactMap { if case .toolCall(let t) = $0 { t } else { nil } }
        #expect(tools.map(\.name) == ["Task", "Task", "Task"])
        #expect(tools.allSatisfy { $0.state == .completed && $0.result != nil })
        #expect(tools.first?.title == "Search for config files")
        #expect(items.filter { if case .agentText = $0 { true } else { false } }.count == 2)
        #expect(items.count == 6, "sidechain rows must stay out of the main transcript")
    }

    @Test func splitsBlocksAndMergesConsecutiveThinking() {
        var t = Transcript()
        t.apply([
            raw("m1", 1, assistant([["type": "thinking", "thinking": "Let me "]])),
            raw("m2", 2, assistant([["type": "thinking", "thinking": "think."], ["type": "text", "text": "Done"]])),
        ])
        #expect(t.items.count == 2)
        guard case .agentText(let thinking) = t.items[0], case .agentText(let text) = t.items[1] else {
            Issue.record("unexpected items \(t.items)"); return
        }
        #expect(thinking.isThinking && thinking.text == "Let me think.")
        #expect(!text.isThinking && text.text == "Done")
    }

    @Test func toolResultArrivingBeforeCallIsApplied() {
        var t = Transcript()
        t.apply([raw("r", 2, agentOutput(["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "tool-1", "content": "ok", "is_error": true],
        ]]]))])
        t.apply([raw("c", 1, assistant([["type": "tool_use", "id": "tool-1", "name": "Bash", "input": ["command": "ls"]]]))])
        guard case .toolCall(let tool)? = t.items.first else { Issue.record("no tool"); return }
        #expect(tool.state == .error)
        #expect(tool.result == "ok")
        #expect(t.items.count == 1)
    }

    @Test func normalizesCodexAndAcpRecords() {
        var t = Transcript()
        t.apply([
            raw("a", 1, ["role": "agent", "content": ["type": "codex", "data": ["type": "message", "message": "Hi from codex"]]]),
            raw("b", 2, ["role": "agent", "content": ["type": "acp", "provider": "opencode", "data": [
                "type": "tool-call", "callId": "call_1", "id": "msg_1", "name": "Bash", "input": #"{"command":"echo hi"}"#]]]),
            raw("c", 3, ["role": "agent", "content": ["type": "acp", "provider": "opencode", "data": [
                "type": "tool-result", "callId": "call_1", "id": "msg_2", "output": "hi"]]]),
            raw("d", 4, ["role": "agent", "content": ["type": "acp", "provider": "opencode", "data": ["type": "thinking", "text": "hmm"]]]),
            raw("e", 5, ["role": "agent", "content": ["type": "codex", "data": ["type": "message", "message": "sidechain", "sidechainId": "x"]]]),
        ])
        #expect(t.items.count == 3)
        guard case .toolCall(let tool) = t.items[1], case .agentText(let thinking) = t.items[2] else { Issue.record("\(t.items)"); return }
        #expect(tool.input["command"] == "echo hi")
        #expect(tool.state == .completed && tool.result == "hi")
        #expect(thinking.isThinking)
    }

    @Test func streamSegmentsUpsertAndStreamKeysAppend() {
        func streamed(_ text: String, segment: String? = nil, key: String? = nil) -> JSONValue {
            var meta: [String: JSONValue] = [:]
            if let segment { meta["happierStreamSegmentV1"] = ["v": 1, "segmentKind": "assistant", "segmentLocalId": .string(segment), "segmentState": "streaming"] }
            if let key { meta["happierStreamKey"] = .string(key) }
            return ["role": "agent", "content": ["type": "acp", "provider": "claude", "data": ["type": "message", "message": .string(text)]], "meta": .object(meta)]
        }
        var t = Transcript()
        t.apply([raw("s1", 1, streamed("Hel", segment: "seg")), raw("s2", 2, streamed("Hello", segment: "seg"))])
        t.apply([raw("k1", 3, streamed("A", key: "k")), raw("k2", 4, streamed("B", key: "k"))])
        #expect(t.items.compactMap { if case .agentText(let a) = $0 { a.text } else { nil } } == ["Hello", "AB"])
    }

    @Test func pendingPermissionAttachesToMatchingToolAndPlaceholdersOtherwise() {
        var t = Transcript()
        t.apply([raw("c", 1, assistant([["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": ["command": "rm -rf build"]]]))])
        t.apply(agentState: ["requests": [
            "toolu_1": ["tool": "Bash", "arguments": ["command": "rm -rf build"], "createdAt": 5],
            "perm_2": ["tool": "Edit", "arguments": ["file_path": "/a"], "createdAt": 6],
        ]])
        let tools = t.items.compactMap { if case .toolCall(let x) = $0 { x } else { nil } }
        #expect(tools.count == 2)
        #expect(tools[0].permission?.status == .pending && tools[0].permission?.id == "toolu_1")
        #expect(tools[1].name == "Edit" && tools[1].permission?.status == .pending)
        #expect(t.pendingPermissions.map(\.id) == ["toolu_1", "perm_2"])

        t.apply(agentState: ["completedRequests": [
            "toolu_1": ["tool": "Bash", "arguments": ["command": "rm -rf build"], "status": "denied", "reason": "nope"],
        ]])
        guard case .toolCall(let denied)? = t.items.first else { Issue.record("no tool"); return }
        #expect(denied.permission?.status == .denied && denied.state == .error)
        #expect(t.pendingPermissions.isEmpty)
    }

    @Test func readyEventsAreHiddenAndUserMessagesDedupeByLocalId() {
        var t = Transcript()
        t.addPending(localId: "L1", text: "hola")
        #expect(t.items.count == 1)
        t.apply([
            raw("u", 1, ["role": "user", "content": ["type": "text", "text": "hola"]], localId: "L1"),
            raw("e", 2, ["role": "agent", "content": ["type": "event", "id": "e", "data": ["type": "ready"]]]),
            raw("s", 3, ["role": "agent", "content": ["type": "event", "id": "s", "data": ["type": "switch", "mode": "local"]]]),
        ])
        #expect(t.items.count == 2)
        guard case .userText(let user) = t.items[0], case .event = t.items[1] else { Issue.record("\(t.items)"); return }
        #expect(!user.isPending)
    }
}

/// A sent message keeps one identity from optimistic bubble to committed row, so the UI updates
/// it in place instead of removing one bubble and inserting another.
@Suite struct UserMessageIdentityTests {
    @Test func pendingAndCommittedShareTheSameId() {
        var t = Transcript()
        t.addPending(localId: "L1", text: "hola")
        let pendingId = t.items.first?.id
        t.apply([TranscriptMessage(id: "server-row", seq: 3, localId: "L1", createdAt: .now,
                                   record: ["role": "user", "content": ["type": "text", "text": "hola"]])])
        #expect(t.items.count == 1)
        #expect(t.items.first?.id == pendingId)
        #expect(pendingId == UserText.stableId(localId: "L1"))
    }
}

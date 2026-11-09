import Foundation
import Testing
@testable import HappierKit

/// Claude Code's slash-command rows (`<command-name>`, `<local-command-stdout>`, ...), forwarded
/// by older CLIs or typed in the terminal, are a compact system line, never the user's bubble.
/// Rows are shaped like real Claude Code JSONL lines.
@Suite struct LocalCommandLineTests {
    private func raw(_ id: String, _ seq: Int, _ record: JSONValue) -> TranscriptMessage {
        TranscriptMessage(id: id, seq: seq, localId: nil, createdAt: Date(timeIntervalSince1970: Double(seq)), record: record)
    }

    private func claudeUser(_ text: String, isMeta: Bool? = nil) -> JSONValue {
        var data: [String: JSONValue] = ["type": "user", "isSidechain": false, "message": ["role": "user", "content": .string(text)]]
        if let isMeta { data["isMeta"] = .bool(isMeta) }
        return ["role": "agent", "content": ["type": "output", "data": .object(data)]]
    }

    private func lines(_ t: Transcript) -> [String] {
        t.items.map { item in
            switch item {
            case .event(let event) where event.kind == "local-command": "line:" + (event.data["text"]?.stringValue ?? "")
            case .event(let event): event.kind
            case .userText(let user): "user:" + user.text
            default: "other"
            }
        }
    }

    @Test func aForwardedModelStdoutIsALineWithTheCatalogName() {
        var t = Transcript()
        // What Manny saw as a blue bubble: the CLI forwarded it as a user message.
        t.apply([raw("u", 1, ["role": "user", "content": ["type": "text", "text": "<local-command-stdout>Set model to claude-opus-5-5</local-command-stdout>"]])])
        #expect(lines(t) == ["line:Model: Opus 5.5"])
    }

    @Test func aTerminalSlashCommandSequenceReadsAsLines() {
        var t = Transcript()
        t.apply([
            raw("c", 1, claudeUser("<local-command-caveat>The command below was run directly in Claude Code, not sent to you as a request, and its output goes straight to the user. It's recorded here as context for later messages.</local-command-caveat>", isMeta: true)),
            raw("n", 2, claudeUser("<command-name>/model</command-name>\n            <command-message>model</command-message>\n            <command-args>opus</command-args>")),
            raw("o", 3, claudeUser("<local-command-stdout>Set model to `opus (claude-opus-5-5)`</local-command-stdout>")),
            raw("e", 4, claudeUser("<local-command-stdout>Set effort level to high (this session only): Comprehensive implementation with extensive testing and documentation</local-command-stdout>")),
            raw("f", 5, claudeUser("<local-command-stdout>Set model to `Fable 5.1` for this session only</local-command-stdout>")),
            raw("m", 6, claudeUser("<command-name>/mcp</command-name>\n            <command-message>mcp</command-message>\n            <command-args></command-args>")),
            raw("s", 7, claudeUser("<local-command-stdout>85 MCP server(s): 18 connected, 42 not connected, 25 not configured, 0 disabled. Use `/mcp` in the terminal for details.</local-command-stdout>")),
            raw("x", 8, claudeUser("<local-command-stdout></local-command-stdout>")),
            raw("k", 9, claudeUser("<command-message>agilgob-review</command-message>\n<command-name>/agilgob-review</command-name>\n<command-args>la PR 12</command-args>")),
            raw("r", 10, claudeUser("<local-command-stderr>Unknown command: /feature-extractor</local-command-stderr>")),
        ])
        // The caveat is hidden; /model and /effort show their result only.
        #expect(lines(t) == [
            "line:Model: Opus 5.5",
            "line:Effort: High",
            "line:Model: Fable 5.1",
            "line:/mcp",
            "line:85 MCP server(s): 18 connected, 42 not connected, 25 not configured, 0 disabled. Use `/mcp` in the terminal for details.",
            "line:/agilgob-review la PR 12",
            "line:Unknown command: /feature-extractor",
        ])
    }

    @Test func theRunnersOwnChangeLineIsntDuplicated() {
        let outcome: JSONValue = ["role": "agent", "content": ["type": "event", "id": "r", "data": [
            "type": "runtime-config-outcome", "runtime": "claude", "status": "applied", "message": "Model changed to Opus 5.5",
            "changes": [["key": "model", "previous": "claude-sonnet-5-5", "effective": "claude-opus-5-5"]]]]]
        let stdout = claudeUser("<local-command-stdout>Set model to claude-opus-5-5</local-command-stdout>")
        var before = Transcript()
        before.apply([raw("o", 1, stdout), raw("r", 2, outcome)])
        #expect(lines(before) == ["runtime-config-outcome"])
        // An agent message streamed after the removed line still grows in place.
        var streamed = Transcript()
        func stream(_ id: String, _ seq: Int, _ text: String) -> TranscriptMessage {
            TranscriptMessage(id: id, seq: seq, localId: nil, createdAt: Date(timeIntervalSince1970: Double(seq)),
                              record: ["role": "agent", "content": ["type": "codex", "data": ["type": "message", "message": .string(text)]],
                                       "meta": ["happierStreamKey": "k1"]])
        }
        streamed.apply([raw("o", 1, stdout), stream("a", 2, "Hola"), raw("r", 3, outcome), stream("b", 4, " mundo")])
        #expect(lines(streamed) == ["other", "runtime-config-outcome"])
        if case .agentText(let text)? = streamed.items.first { #expect(text.text == "Hola mundo") } else { Issue.record("\(streamed.items)") }
        var after = Transcript()
        after.apply([raw("r", 1, outcome), raw("o", 2, stdout)])
        #expect(lines(after) == ["runtime-config-outcome"])
    }

    @Test func ordinaryUserTextIsUntouched() {
        var t = Transcript()
        t.apply([raw("u", 1, ["role": "user", "content": ["type": "text", "text": "what does <command-name> mean?"]])])
        #expect(lines(t) == ["user:what does <command-name> mean?"])
    }
}

import Foundation
import Testing
@testable import HappierKit

/// What a tool card shows (`normalizeToolCallForRendering`, `renderers/fileOps|system|workflow|web`).
@Suite struct ToolRenderingTests {
    private func tool(_ name: String, _ input: JSONValue, result: JSONValue? = nil, structured: JSONValue? = nil,
                      state: ToolCall.State = .completed) -> ToolCall {
        var call = ToolCall(id: "t", itemId: "t", name: name, input: input, title: nil, state: state, result: result,
                            permission: nil, createdAt: .now)
        call.structuredResult = structured
        return call
    }

    // MARK: Claude's structured result

    @Test func claudeToolResultsKeepTheirStructuredForm() {
        var transcript = Transcript()
        let user: JSONValue = ["role": "agent", "content": ["type": "output", "data": [
            "type": "user",
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "r1", "content": "1\tline"]]],
            "toolUseResult": ["type": "text", "file": ["filePath": "/a.swift", "content": "line", "startLine": 1]],
        ]]]
        let call: JSONValue = ["role": "agent", "content": ["type": "output", "data": [
            "type": "assistant", "message": ["role": "assistant", "content": [["type": "tool_use", "id": "r1", "name": "Read", "input": ["file_path": "/a.swift"]]]],
        ]]]
        transcript.apply([
            TranscriptMessage(id: "1", seq: 1, localId: nil, createdAt: .now, record: call),
            TranscriptMessage(id: "2", seq: 2, localId: nil, createdAt: .now, record: user),
        ])
        guard case .toolCall(let read)? = transcript.items.first else { Issue.record("no tool"); return }
        #expect(read.result == "1\tline")
        #expect(read.structuredResult?["file"]?["content"] == "line")
    }

    // MARK: Canonical names

    @Test func namesFollowTheCLIsCanonicalNameThenTheRawName() {
        #expect(ToolRendering.canonicalName(tool("CodexBash", ["command": "ls", "_happier": ["v": 2, "canonicalToolName": "Bash"]])) == "Bash")
        #expect(ToolRendering.canonicalName(tool("execute", ["command": "ls"])) == "Bash")
        #expect(ToolRendering.canonicalName(tool("apply_patch", ["patch": "x"])) == "Patch")
        #expect(ToolRendering.canonicalName(tool("edit", ["path": "/a", "edits": [["old_string": "a", "new_string": "b"]]])) == "MultiEdit")
        #expect(ToolRendering.canonicalName(tool("edit", ["path": "/a", "content": "x"])) == "Write")
        #expect(ToolRendering.canonicalName(tool("edit", ["path": "/a", "changes": ["/a": ["type": "add", "content": "x"]]])) == "Patch")
        #expect(ToolRendering.canonicalName(tool("write", ["todos": [["content": "a", "status": "pending"]]])) == "TodoWrite")
        #expect(ToolRendering.canonicalName(tool("fetch", ["url": "https://x"])) == "WebFetch")
        #expect(ToolRendering.canonicalName(tool("Agent", ["prompt": "x"])) == "SubAgent")
        #expect(ToolRendering.canonicalName(tool("mcp__linear__create_issue", [:])) == "mcp__linear__create_issue")
        #expect(ToolRendering.canonicalName(tool("Grep", [:])) == "Grep")
    }

    @Test func mcpToolsReadAsServerAndAction() {
        #expect(ToolRendering.mcpTitle("mcp__linear__create_issue") == "Linear: Create Issue")
        #expect(ToolRendering.mcpTitle("Bash") == nil)
    }

    // MARK: Bodies

    @Test func editsShowADiff() {
        guard case .diff(let files) = ToolRendering.body(tool("Edit", ["file_path": "/a.swift", "old_string": "let a = 1", "new_string": "let a = 2"])) else {
            Issue.record("not a diff"); return
        }
        #expect(files.map(\.path) == ["/a.swift"] && files[0].diff.added == 1 && files[0].diff.removed == 1)

        guard case .diff(let multi) = ToolRendering.body(tool("MultiEdit", ["file_path": "/b", "edits": [
            ["old_string": "a", "new_string": "b"], ["old_string": "c", "new_string": "d"],
        ]])) else { Issue.record("not a diff"); return }
        #expect(multi.count == 2 && multi.allSatisfy { $0.path == "/b" })

        guard case .diff(let write) = ToolRendering.body(tool("Write", ["file_path": "/n.md", "content": "# A\nB"])) else {
            Issue.record("not a diff"); return
        }
        #expect(write[0].diff.added == 2 && write[0].diff.removed == 0)
    }

    @Test func patchesShowEachFile() {
        guard case .diff(let fromMap) = ToolRendering.body(tool("Patch", ["changes": [
            "src/a.ts": ["type": "update", "unified_diff": "@@ -1 +1 @@\n-a\n+b"],
            "b.md": ["type": "add", "content": "hi"],
            "c.txt": ["type": "delete", "content": "bye"],
        ]])) else { Issue.record("not a diff"); return }
        #expect(fromMap.map(\.path) == ["b.md", "c.txt", "src/a.ts"])
        #expect(fromMap[1].isDeletion && fromMap[1].diff.removed == 1)
        #expect(fromMap[2].diff.added == 1)

        guard case .diff(let fromText) = ToolRendering.body(tool("Patch", ["patch": "*** Begin Patch\n*** Add File: x.md\n+hi\n*** End Patch"])) else {
            Issue.record("not a diff"); return
        }
        #expect(fromText.map(\.path) == ["x.md"])

        guard case .diff(let turn) = ToolRendering.body(tool("Diff", ["files": [["file_path": "a", "unified_diff": "@@ -1 +1 @@\n-x\n+y"]]])) else {
            Issue.record("not a diff"); return
        }
        #expect(turn.map(\.path) == ["a"] && turn[0].diff.added == 1)
    }

    @Test func shellCommandsShowOutputAndExitStatus() {
        guard case .shell(let command, let output, let errors, let exit) = ToolRendering.body(
            tool("Bash", ["command": "ls"], result: "ignored", structured: ["stdout": "a\nb", "stderr": "warn", "interrupted": false])
        ) else { Issue.record("not shell"); return }
        #expect(command == "ls" && output == "a\nb" && errors == "warn" && exit == nil)

        guard case .shell(_, let codexOut, _, let codexExit) = ToolRendering.body(
            tool("CodexBash", ["command": ["bash", "-lc", "make"], "_happier": ["canonicalToolName": "Bash"]],
                 result: ["stdout": "built", "exit_code": 2])
        ) else { Issue.record("not shell"); return }
        #expect(codexOut == "built" && codexExit == 2)

        guard case .shell(_, let plain, _, _) = ToolRendering.body(tool("execute", ["command": "pwd"], result: "/home")) else {
            Issue.record("not shell"); return
        }
        #expect(plain == "/home")
    }

    @Test func readsShowTheFile() {
        guard case .file(let path, let text, let start) = ToolRendering.body(
            tool("Read", ["file_path": "/a.swift"], result: "     1\tlet a", structured: ["file": ["content": "let a", "startLine": 10]])
        ) else { Issue.record("not a file"); return }
        #expect(path == "/a.swift" && text == "let a" && start == 10)

        guard case .file(_, let fromCLI, let line) = ToolRendering.body(tool("read", ["path": "/b"], result: ["file": ["content": "x"]])) else {
            Issue.record("not a file"); return
        }
        #expect(fromCLI == "x" && line == 1)
    }

    @Test func searchesListTheirMatches() {
        guard case .list(let claudeGlob) = ToolRendering.body(tool("Glob", ["pattern": "*.ts"], structured: ["filenames": ["a.ts", "b.ts"], "numFiles": 2])) else {
            Issue.record("not a list"); return
        }
        #expect(claudeGlob == ["a.ts", "b.ts"])
        guard case .list(let grep) = ToolRendering.body(tool("Grep", ["pattern": "x"], result: ["matches": [["filePath": "a.ts", "line": 3, "excerpt": "x()"]]])) else {
            Issue.record("not a list"); return
        }
        #expect(grep == ["a.ts:3  x()"])
        guard case .list(let ls) = ToolRendering.body(tool("LS", ["path": "/"], result: ["entries": ["bin", "etc"]])) else {
            Issue.record("not a list"); return
        }
        #expect(ls == ["bin", "etc"])
    }

    @Test func todoListsShowEachItemsStatus() {
        guard case .todos(let todos) = ToolRendering.body(tool("TodoWrite", ["todos": [
            ["content": "Plan", "status": "completed", "activeForm": "Planning"],
            ["content": "Build", "status": "in_progress"],
            ["content": "Ship", "status": "todo"],
        ]], structured: ["newTodos": [["content": "Plan", "status": "completed"], ["content": "Build", "status": "in_progress"], ["content": "Ship", "status": "pending"]]])) else {
            Issue.record("not todos"); return
        }
        #expect(todos.map(\.text) == ["Plan", "Build", "Ship"])
        #expect(todos.map(\.status) == [.completed, .inProgress, .pending])
    }

    @Test func plansAndFetchesShowMarkdown() {
        #expect(ToolRendering.body(tool("ExitPlanMode", ["plan": "# Plan"])) == .markdown("# Plan"))
        #expect(ToolRendering.body(tool("WebFetch", ["url": "https://x"], structured: ["result": "Page **summary**", "code": 200])) == .markdown("Page **summary**"))
    }

    @Test func mcpToolsShowTheirText() {
        #expect(ToolRendering.body(tool("mcp__linear__get", ["id": "1"], result: [["type": "text", "text": "Issue 1"]])) == .text("Issue 1"))
    }

    @Test func otherToolsFallBackToRawDetails() {
        #expect(ToolRendering.body(tool("Mystery", ["a": 1], result: "x")) == nil)
    }
}

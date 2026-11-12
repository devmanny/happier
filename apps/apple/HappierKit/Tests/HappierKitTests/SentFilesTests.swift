import Foundation
import Testing
@testable import HappierKit

/// Files the agent sent with Claude Code's `SendUserFile` (`{files, caption?, status, display?}`,
/// structured result `{caption?, display?, attachments: [{path, size, isImage, media_type?}]}`,
/// Claude Code 2.1.322): what the conversation shows of them.
@Suite struct SentFilesTests {
    private let path = "/private/tmp/claude-501/-Users-manny-Projects-radar/12ccad1a-7379-47c9-91ee-6f1a3dd8103c/scratchpad/manny-v2-prueba.mp3"
    private let caption = "Prueba de «Manny v2» con el modelo que usan los videos (eleven_v4)"

    private func send(_ input: JSONValue, id: String = "toolu_1", state: ToolCall.State = .completed, structured: JSONValue? = nil,
                      permission: ToolPermission? = nil) -> ToolCall {
        var call = ToolCall(id: id, itemId: "i-\(id)", name: "SendUserFile", input: input, title: nil, state: state,
                            result: state == .running ? nil : "1 file delivered to user.", permission: permission, createdAt: .now)
        call.structuredResult = structured
        return call
    }

    /// The rows Claude Code wrote for the real send (session cmvhdaw4x7lotnw01rib8trqr, trimmed).
    @Test func theRealSendShowsTheAudioFileItSentWithItsCaption() throws {
        let call: JSONValue = ["role": "agent", "content": ["type": "output", "data": [
            "type": "assistant", "isSidechain": false,
            "message": ["role": "assistant", "content": [[
                "type": "tool_use", "id": "toolu_01LCoooHZGH2dVpq6rpd7gwE", "name": "SendUserFile",
                "input": ["files": [.string(path)], "caption": .string(caption), "status": "normal"],
            ]]],
        ]]]
        let result: JSONValue = ["role": "agent", "content": ["type": "output", "data": [
            "type": "user", "isSidechain": false,
            "message": ["role": "user", "content": [[
                "tool_use_id": "toolu_01LCoooHZGH2dVpq6rpd7gwE", "type": "tool_result",
                "content": .string("1 file delivered to user.\n  \(path) → file_uuid: dffc144c-9e14-494c-b902-4164f3b8a125"),
            ]]],
            "toolUseResult": ["caption": .string(caption), "attachments": [[
                "path": .string(path), "size": 69006, "isImage": false, "media_type": "audio/mpeg",
                "pathValidated": true, "file_uuid": "dffc144c-9e14-494c-b902-4164f3b8a125",
            ]]],
        ]]]
        var transcript = Transcript()
        transcript.apply([
            TranscriptMessage(id: "a", seq: 30, localId: nil, createdAt: .now, record: call),
            TranscriptMessage(id: "b", seq: 31, localId: nil, createdAt: .now, record: result),
        ])
        guard case .toolCall(let tool)? = transcript.items.first else { Issue.record("no tool call"); return }
        let sent = try #require(tool.sentFiles)
        #expect(sent.caption == caption)
        #expect(sent.files.count == 1)
        let file = try #require(sent.files.first)
        #expect(file.name == "manny-v2-prueba.mp3")
        #expect(file.path == path)
        #expect(file.mimeType == "audio/mpeg")
        #expect(file.sizeBytes == 69006)
        #expect(!sent.attachOnly)
    }

    @Test func severalFilesShowFromTheCallBeforeItsResultAndABlankCaptionIsNone() throws {
        let running = send(["files": ["/Users/manny/out/chart.png", "docs/report.pdf"], "caption": "  ", "status": "normal"], state: .running)
        let sent = try #require(running.sentFiles)
        #expect(sent.files.map(\.name) == ["chart.png", "report.pdf"])
        // A relative path stays relative: the download route resolves it in the session's folder.
        #expect(sent.files.map(\.path) == ["/Users/manny/out/chart.png", "docs/report.pdf"])
        #expect(sent.caption == nil)
        #expect(sent.files[0].isImage)
        // The tool also takes one path as a string.
        #expect(send(["files": "notes.md", "status": "normal"]).sentFiles?.files.map(\.name) == ["notes.md"])
    }

    @Test func aProactiveSendOrOneWithoutAStatusShowsTheSameFiles() {
        let normal = send(["files": ["/r/a.pdf"], "caption": "Report", "status": "normal"]).sentFiles
        #expect(normal != nil)
        #expect(send(["files": ["/r/a.pdf"], "caption": "Report", "status": "proactive"]).sentFiles == normal)
        #expect(send(["files": ["/r/a.pdf"], "caption": "Report"]).sentFiles == normal)
    }

    @Test func attachDisplayAsksForFileCardsInsteadOfInlinePreviews() {
        #expect(send(["files": ["/r/a.png"], "status": "normal", "display": "attach"]).sentFiles?.attachOnly == true)
        #expect(send(["files": ["/r/a.png"], "status": "normal", "display": "render"]).sentFiles?.attachOnly == false)
        #expect(send(["files": ["/r/a.png"], "status": "normal"]).sentFiles?.attachOnly == false)
    }

    @Test func onlyDeliveredOrDeliveringSendsAreSentFiles() {
        let input: JSONValue = ["files": ["/r/a.pdf"], "status": "normal"]
        // Refused or failed: nothing reached the user, it stays an ordinary failed step.
        #expect(send(input, state: .error).sentFiles == nil)
        // Waiting for approval: the approval card asks first.
        #expect(send(input, state: .running, permission: ToolPermission(id: "toolu_1", status: .pending, kind: .permission, reason: nil, decision: nil)).sentFiles == nil)
        #expect(send(["files": [], "status": "normal"]).sentFiles == nil)
        let other = ToolCall(id: "t", itemId: "t", name: "Read", input: ["files": ["/r/a.pdf"]], title: nil, state: .completed,
                             result: nil, permission: nil, createdAt: .now)
        #expect(other.sentFiles == nil)
    }

    /// The tool re-sends a file when it changed; the computer only has its newest bytes, so each
    /// send keeps its own download instead of showing another send's copy.
    @MainActor @Test func sendsOfOnePathAreDownloadedSeparately() throws {
        let input: JSONValue = ["files": ["/r/chart.png"], "status": "normal"]
        let first = try #require(send(input, id: "toolu_1").sentFiles?.files.first)
        let again = try #require(send(input, id: "toolu_1").sentFiles?.files.first)
        let later = try #require(send(input, id: "toolu_2").sentFiles?.files.first)
        let sessionId = "sent-files-test-" + UUID().uuidString
        let urls = [first, again, later].map { HappierStore.attachmentCacheURL(for: $0, sessionId: sessionId) }
        defer { for url in urls { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
        #expect(urls[0] == urls[1])
        #expect(urls[0] != urls[2])
        #expect(urls.allSatisfy { $0.lastPathComponent == "chart.png" })
    }
}

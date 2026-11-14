import Foundation
import Testing
@testable import HappierKit

/// Turn folding: the agent's messages always show; the steps between them (thinking, tools,
/// events) fold into one line each.
@Suite struct TurnFoldingTests {
    private func tool(_ id: String, pending: Bool = false, at t: Double = 0) -> ChatItem {
        .toolCall(ToolCall(id: id, itemId: "i-\(id)", name: "Bash", input: .null, title: nil, state: .completed, result: nil,
                           permission: pending ? ToolPermission(id: id, status: .pending, kind: .permission, reason: nil, decision: nil) : nil,
                           createdAt: Date(timeIntervalSince1970: t)))
    }
    private func text(_ id: String, thinking: Bool = false, at t: Double = 0) -> ChatItem {
        .agentText(AgentText(id: id, text: id, isThinking: thinking, createdAt: Date(timeIntervalSince1970: t)))
    }
    private func user(_ id: String, at t: Double = 0) -> ChatItem {
        .userText(UserText(id: id, text: id, createdAt: Date(timeIntervalSince1970: t), localId: nil, isPending: false))
    }

    private func shape(_ rows: [ChatRow]) -> [String] {
        rows.map { row in
            switch row {
            case .item(.userText(let u)): "user:\(u.id)"
            case .item(.agentText(let a)): "text:\(a.id)"
            case .item(.toolCall(let t)): "tool:\(t.id)"
            case .item(.event): "event"
            case .work(let steps, _, let inProgress): "work\(steps.count)\(inProgress ? "…" : "")"
            case .tools(let tools, _): "tools\(tools.count)"
            }
        }
    }

    @Test func messagesStayVisibleAndOnlyTheStepsBetweenThemFold() {
        let items = [user("q"), text("plan", thinking: true), text("narration"), tool("1"), tool("2"), text("answer"), user("q2"), text("short")]
        #expect(shape(ChatRow.rows(from: items, working: false)) == ["user:q", "work1", "text:narration", "work2", "text:answer", "user:q2", "text:short"])
    }

    @Test func runningTurnShowsItsMessagesAndFoldsTheStepsInProgress() {
        let items = [user("q"), text("narration"), tool("1")]
        #expect(shape(ChatRow.rows(from: items, working: true)) == ["user:q", "text:narration", "work1…"])
        // Only the latest run of a running turn is in progress.
        let more = [user("q"), tool("1"), text("narration"), tool("2")]
        #expect(shape(ChatRow.rows(from: more, working: true)) == ["user:q", "work1", "text:narration", "work1…"])
    }

    @Test func modelChangeAndCommandLinesStayOutOfTheFoldedSteps() {
        func event(_ kind: String) -> ChatItem {
            .event(TranscriptEvent(id: kind, kind: kind, data: ["message": "Model changed to Opus 5.5", "text": "/mcp"], createdAt: .distantPast))
        }
        let items = [user("q"), tool("1"), event("runtime-config-outcome"), tool("2"), event("local-command"), text("done")]
        #expect(shape(ChatRow.rows(from: items, working: false)) == ["user:q", "work1", "event", "work1", "event", "text:done"])
        // Other events (a ready, a switch) still fold with the steps.
        #expect(shape(ChatRow.rows(from: [user("q"), tool("1"), event("switch"), text("done")], working: false)) == ["user:q", "work2", "text:done"])
    }

    @Test func aNoticeFromTheRunnerStaysInTheConversation() {
        // "Claude's terminal did not become ready…": said to the user, so it isn't folded away.
        let notice = ChatItem.event(TranscriptEvent(id: "n", kind: "message", data: ["message": "Your queued message is paused"], createdAt: .distantPast))
        #expect(shape(ChatRow.rows(from: [user("q"), tool("1"), notice], working: false)) == ["user:q", "work1", "event"])
        #expect(shape(ChatRow.rows(from: [user("q"), notice, tool("1"), text("done")], working: false)) == ["user:q", "event", "work1", "text:done"])
    }

    @Test func pendingApprovalsStayVisible() {
        let items = [user("q"), tool("1"), tool("2", pending: true)]
        #expect(shape(ChatRow.rows(from: items, working: true)) == ["user:q", "work1…", "tool:2"])
    }

    @Test func answeredQuestionsStayVisibleOutsideFoldedWorkAndToolGroups() {
        let question = ChatItem.toolCall(ToolCall(
            id: "question", itemId: "i-question", name: "AskUserQuestion",
            input: ["questions": [["question": "Where?", "options": ["Calendar", "Reminder"]]]],
            title: nil, state: .completed, result: ["answers": ["Where?": ["Calendar"]]],
            permission: nil, createdAt: .distantPast))
        let items = [tool("before"), question, tool("after"), text("done")]
        #expect(shape(ChatRow.rows(from: items, working: false)) == ["work1", "tool:question", "work1", "text:done"])
        #expect(shape(ChatRow.groupTools(items)) == ["tool:before", "tool:question", "tool:after", "text:done"])
    }

    /// A file the agent sent reaches the user like a message: it stays out of the folded steps.
    @Test func sentFilesShowLikeAMessage() {
        func sendFile(_ id: String, state: ToolCall.State) -> ChatItem {
            .toolCall(ToolCall(id: id, itemId: "i-\(id)", name: "SendUserFile", input: ["files": ["/r/report.pdf"], "status": "normal"],
                               title: nil, state: state, result: nil, permission: nil, createdAt: .distantPast))
        }
        let items = [user("q"), tool("1"), sendFile("file", state: .completed), tool("2"), text("done")]
        #expect(shape(ChatRow.rows(from: items, working: false)) == ["user:q", "work1", "tool:file", "work1", "text:done"])
        // Mid-turn, the steps before it are done; only the ones after it are in progress.
        #expect(shape(ChatRow.rows(from: Array(items.prefix(4)), working: true)) == ["user:q", "work1", "tool:file", "work1…"])
        // A send that failed delivered nothing: it folds as a failed step.
        #expect(shape(ChatRow.rows(from: [user("q"), sendFile("file", state: .error), text("done")], working: false)) == ["user:q", "work1", "text:done"])
    }

    @Test func expandedStepsGroupConsecutiveTools() {
        let steps = [text("a"), tool("1"), tool("2"), text("b"), tool("3")]
        #expect(shape(ChatRow.groupTools(steps)) == ["text:a", "tools2", "text:b", "tool:3"])
    }

    @Test func workIdStaysStableAsTheTurnGrows() {
        let before = ChatRow.rows(from: [user("q"), tool("1")], working: true)
        let after = ChatRow.rows(from: [user("q"), tool("1"), tool("2"), text("done")], working: false)
        #expect(before[1].id == after[1].id)
    }

    @Test func workDurationSpansFromTheUserMessageToTheLastStep() {
        let rows = ChatRow.rows(from: [user("q", at: 100), tool("1", at: 130), text("answer", at: 292)], working: false)
        guard case .work(let steps, _, _) = rows[1] else { Issue.record("no work row"); return }
        #expect(ChatRow.workDuration(steps: steps, startedAt: Date(timeIntervalSince1970: 100), endedAt: Date(timeIntervalSince1970: 292)) == 192)
    }

    @Test func drawsOnlyTheNewestRowsAndWidensToReachAMatch() {
        let rows = (0..<500).map { ChatRow.item(user("u\($0)")) }
        #expect(ChatWindow.visible(rows, limit: ChatWindow.initial).first?.id == "u\(500 - ChatWindow.initial)")
        #expect(ChatWindow.visible(rows, limit: 10_000).count == 500)
        // Jumping to an older search match widens the window just enough (plus a little context).
        let limit = ChatWindow.limit(including: "u100", in: rows, current: ChatWindow.initial)
        #expect(ChatWindow.visible(rows, limit: limit).contains { $0.id == "u100" })
        #expect(ChatWindow.limit(including: "u480", in: rows, current: ChatWindow.initial) == ChatWindow.initial)
    }

    @Test func aReaderScrolledUpKeepsTheFirstDrawnRowAsNewRowsArrive() {
        let rows = (0..<100).map { ChatRow.item(user("u\($0)")) }
        let start = ChatWindow.visible(rows, limit: ChatWindow.initial).first?.id
        // Two new messages arrive while the reader is up in the history: nothing drawn above them
        // is dropped, so the content doesn't slide under the reader.
        let grown = rows + [ChatRow.item(user("u100")), ChatRow.item(user("u101"))]
        #expect(ChatWindow.visible(grown, limit: ChatWindow.initial, keeping: start).first?.id == start)
        // Back at the end (no row kept) the window is the newest rows again.
        #expect(ChatWindow.visible(grown, limit: ChatWindow.initial, keeping: nil).first?.id == "u62")
        // A kept row inside the newest rows doesn't shrink the window, and one that's gone is ignored.
        #expect(ChatWindow.visible(grown, limit: ChatWindow.initial, keeping: "u90").count == ChatWindow.initial)
        #expect(ChatWindow.visible(grown, limit: ChatWindow.initial, keeping: "gone").count == ChatWindow.initial)
    }
}

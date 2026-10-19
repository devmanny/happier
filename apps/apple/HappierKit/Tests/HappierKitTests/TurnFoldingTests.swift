import Foundation
import Testing
@testable import HappierKit

/// Turn folding: each agent turn's work collapses to one line; only the final answer stays visible.
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

    @Test func foldsTheTurnAndKeepsOnlyTheFinalAnswer() {
        let items = [user("q"), text("plan", thinking: true), text("narration"), tool("1"), tool("2"), text("answer"), user("q2"), text("short")]
        #expect(shape(ChatRow.rows(from: items, working: false)) == ["user:q", "work4", "text:answer", "user:q2", "text:short"])
    }

    @Test func runningTurnFoldsEverythingWithoutAFinalAnswer() {
        let items = [user("q"), text("narration"), tool("1")]
        #expect(shape(ChatRow.rows(from: items, working: true)) == ["user:q", "work2…"])
    }

    @Test func pendingApprovalsStayVisible() {
        let items = [user("q"), tool("1"), tool("2", pending: true)]
        #expect(shape(ChatRow.rows(from: items, working: true)) == ["user:q", "work1…", "tool:2"])
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
}

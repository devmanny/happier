import Foundation
import Testing
@testable import HappierKit

@Suite struct ToolGroupingTests {
    private func tool(_ id: String, pending: Bool = false) -> ChatItem {
        .toolCall(ToolCall(id: id, itemId: "i-\(id)", name: "Bash", input: .null, title: nil, state: .completed, result: nil,
                           permission: pending ? ToolPermission(id: id, status: .pending, kind: .permission, reason: nil, decision: nil) : nil,
                           createdAt: .now))
    }
    private func text(_ id: String) -> ChatItem { .agentText(AgentText(id: id, text: id, isThinking: false, createdAt: .now)) }

    @Test func groupsRunsOfTwoOrMoreToolsButNotSinglesOrPendingApprovals() {
        let rows = ChatRow.rows(from: [text("a"), tool("1"), tool("2"), tool("3"), text("b"), tool("4"), tool("5", pending: true), tool("6"), tool("7")])
        let shape = rows.map { row -> String in
            switch row {
            case .item(let item): if case .toolCall = item { "tool" } else { "item" }
            case .tools(let tools, _): "group\(tools.count)"
            }
        }
        #expect(shape == ["item", "group3", "item", "tool", "tool", "group2"])
    }

    @Test func groupIdIsStableAcrossAppends() {
        let before = ChatRow.rows(from: [tool("1"), tool("2")])
        let after = ChatRow.rows(from: [tool("1"), tool("2"), tool("3")])
        #expect(before.first?.id == after.first?.id)
    }
}

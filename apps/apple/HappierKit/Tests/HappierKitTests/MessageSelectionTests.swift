import Foundation
import Testing
@testable import HappierKit

/// Multi-select copy (`formatSelectedMessagesForClipboard.ts`).
@Suite struct MessageSelectionTests {
    private let user = ChatItem.userText(UserText(id: "u", text: "Fix the login", createdAt: .now, localId: nil, isPending: false))
    private let agent = ChatItem.agentText(AgentText(id: "a", text: "Done — tests pass.", isThinking: false, createdAt: .now))
    private let thinking = ChatItem.agentText(AgentText(id: "t", text: "hmm", isThinking: true, createdAt: .now))

    @Test func singleRoleIsPlainText() {
        #expect(MessageSelection.clipboardText([agent, agent], agentName: "Claude Code") == "Done — tests pass.\n\nDone — tests pass.")
    }

    @Test func mixedRolesAreLabelled() {
        #expect(MessageSelection.clipboardText([user, agent], agentName: "Claude Code")
            == "**You:**\n\nFix the login\n\n**Claude Code:**\n\nDone — tests pass.")
    }

    @Test func onlyNonEmptyTextMessagesAreSelectable() {
        #expect(MessageSelection.isSelectable(user) && MessageSelection.isSelectable(agent))
        #expect(!MessageSelection.isSelectable(thinking))
    }
}

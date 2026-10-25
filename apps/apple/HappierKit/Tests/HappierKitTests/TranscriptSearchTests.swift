import Foundation
import Testing
@testable import HappierKit

/// Search inside the open conversation: the messages you and the agent wrote.
@Suite struct TranscriptSearchTests {
    private func user(_ id: String, _ text: String) -> ChatItem {
        .userText(UserText(id: id, text: text, createdAt: .now, localId: nil, isPending: false))
    }
    private func agent(_ id: String, _ text: String, thinking: Bool = false) -> ChatItem {
        .agentText(AgentText(id: id, text: text, isThinking: thinking, createdAt: .now))
    }

    @Test func findsMessagesIgnoringCaseAndAccents() {
        let items = [
            user("u1", "Revisa la Facturación de octubre"),
            agent("a1", "Pensando en facturacion", thinking: true),
            agent("a2", "La FACTURACION ya quedó"),
            user("u2", "gracias"),
        ]
        #expect(TranscriptSearch.matches(in: items, query: "facturación") == ["u1", "a2"])
        #expect(TranscriptSearch.matches(in: items, query: "  ").isEmpty)
    }
}

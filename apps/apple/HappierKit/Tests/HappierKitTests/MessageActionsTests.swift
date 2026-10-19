import Foundation
import Testing
@testable import HappierKit

/// Per-message actions (`MessageView.tsx` action row, `sessionMessagePins.ts`, `rollbackUiSupport.ts`).
@Suite struct MessageActionsTests {
    @Test func transcriptItemsCarryTheirMessageSeq() {
        var t = Transcript()
        t.apply([
            TranscriptMessage(id: "u", seq: 7, localId: "L", createdAt: .now, record: ["role": "user", "content": ["type": "text", "text": "hi"]]),
            TranscriptMessage(id: "a", seq: 8, localId: nil, createdAt: .now, record: ["role": "agent", "content": ["type": "codex", "data": ["type": "message", "message": "hello"]]]),
        ])
        t.addPending(localId: "P", text: "later")
        let seqs = t.items.map { item -> Int? in
            switch item {
            case .userText(let u): u.seq
            case .agentText(let a): a.seq
            default: nil
            }
        }
        #expect(seqs == [7, 8, nil])
    }

    @Test func pinsToggleAndPersistPerSession() throws {
        let defaults = try #require(UserDefaults(suiteName: "pins-test-\(UUID().uuidString)"))
        var pins = MessagePins(defaults: defaults, scope: "server/account")
        pins.toggle(sessionId: "s", seq: 4, role: .user)
        pins.toggle(sessionId: "s", seq: 2, role: .assistant)
        #expect(pins.pinned(sessionId: "s").map(\.seq) == [2, 4])
        #expect(pins.isPinned(sessionId: "s", seq: 4))

        let reloaded = MessagePins(defaults: defaults, scope: "server/account")
        #expect(reloaded.pinned(sessionId: "s").map(\.seq) == [2, 4])

        pins.toggle(sessionId: "s", seq: 4, role: .user)
        #expect(!pins.isPinned(sessionId: "s", seq: 4))
        #expect(MessagePins(defaults: defaults, scope: "other").pinned(sessionId: "s").isEmpty)
    }

    @Test func rollbackOnlyForSupportingAgentsAndEligibleTurnStarts() throws {
        func session(flavor: String, active: Bool) throws -> Session {
            try Session(row: ["id": "s", "seq": 9, "createdAt": 1, "updatedAt": 1, "active": .bool(active), "activeAt": 1,
                              "encryptionMode": "plain", "metadata": .string(#"{"path":"/a","flavor":"\#(flavor)"}"#), "metadataVersion": 1,
                              "rollbackEligibleTurnStarts": [3, 7]], keys: nil)
        }
        #expect(try session(flavor: "codex", active: true).canRollback(toUserMessageSeq: 7))
        #expect(try !session(flavor: "codex", active: true).canRollback(toUserMessageSeq: 5))
        #expect(try !session(flavor: "codex", active: false).canRollback(toUserMessageSeq: 7))
        #expect(try !session(flavor: "claude", active: true).canRollback(toUserMessageSeq: 7))
    }
}

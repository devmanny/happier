import Foundation
import Testing
@testable import HappierKit

@Suite struct SessionMessageTests {
    // Captured at HTTP enqueue from real sendSessionMessage after MCP SDK → action_execute,
    // with an empty environment and a target prefix resolved to its full session ID.
    static let record = try! JSONValue.parse(#"""
{
  "role": "user",
  "content": {
    "type": "text",
    "text": "-message"
  },
  "meta": {
    "happier": {
      "kind": "session_message.v1",
      "payload": {
        "senderSessionId": "c987654321098765432109876",
        "targetSessionId": "c123456789012345678901234"
      }
    },
    "sentFrom": "cli",
    "source": "ui",
    "permissionMode": "default"
  }
}
"""#)

    @Test func sessionMessagesRemainSelectableButAreNeverLabelledAsYou() {
        var transcript = Transcript()
        transcript.apply([TranscriptMessage(id: "from-session", seq: 1, localId: "message-local", createdAt: .now, record: Self.record)])
        let message = transcript.items[0]
        let human = ChatItem.userText(UserText(id: "human", text: "Please review", createdAt: .now, localId: nil, isPending: false))
        let agent = ChatItem.agentText(AgentText(id: "agent", text: "On it", isThinking: false, createdAt: .now))
        #expect(MessageSelection.isSelectable(message))
        #expect(MessageSelection.clipboardText([human, message, agent], agentName: "Claude")
            == "**You:**\n\nPlease review\n\n**Session c987654321098765432109876:**\n\n-message\n\n**Claude:**\n\nOn it")
    }

    @Test func parsesOnlyExactEnvelopeWithNonblankOpaqueIds() throws {
        let meta = Self.record["meta"]!
        let origin = try #require(SessionMessageOrigin.parse(meta))
        #expect(origin.senderSessionId == "c987654321098765432109876")
        #expect(origin.targetSessionId == "c123456789012345678901234")
        let opaque: JSONValue = ["happier": ["kind": "session_message.v1", "payload": ["senderSessionId": " sender bytes ", "targetSessionId": " target bytes ", "future": true]]]
        #expect(SessionMessageOrigin.parse(opaque)?.senderSessionId == " sender bytes ")
        #expect(SessionMessageOrigin.parse(opaque)?.targetSessionId == " target bytes ")
        let malformed: [JSONValue?] = [
            nil, .null, ["source": "ui", "sentFrom": "cli"],
            ["happier": ["kind": "session_message.v2", "payload": ["senderSessionId": "s", "targetSessionId": "t"]]],
            ["happier": ["kind": "session_message.v1", "payload": ["senderSessionId": " ", "targetSessionId": "t"]]],
            ["happier": ["kind": "session_message.v1", "payload": ["senderSessionId": "s", "targetSessionId": "\n\t"]]],
            ["happier": ["kind": "session_message.v1", "payload": ["senderSessionId": 123, "targetSessionId": "t"]]],
            ["happier": ["kind": "session_message.v1", "payload": ["senderSessionId": "s"]]],
        ]
        for meta in malformed {
            #expect(SessionMessageOrigin.parse(meta) == nil)
            var transcript = Transcript()
            transcript.apply([row("human", record: record(text: "ordinary human content", meta: meta))])
            guard case .userText(let human)? = transcript.items.first else { Issue.record("missing human"); return }
            #expect(human.sessionMessageOrigin == nil && human.sessionNotice == nil)
            #expect(MessageSelection.clipboardText([.userText(human)], agentName: "Claude") == "ordinary human content")
        }
    }

    @Test func queueEditsAndCommittedHistoryPreserveOriginTextAndIdentity() throws {
        let text = "  A complete message\nwith **Markdown** and trailing spaces  "
        var meta = Self.record["meta"]!.objectValue!
        meta["displayText"] = "short preview"
        let raw = record(text: text, meta: .object(meta))
        let queueRow: JSONValue = ["localId": "message-local", "content": ["t": "plain", "v": raw], "status": "queued", "position": 1, "createdAt": 1000]
        let pending = try #require(PendingMessage.list([queueRow], session: plainSession()).first)
        #expect(pending.text == text && pending.record == raw && pending.state == .queued)
        let origin = try #require(pending.sessionMessageOrigin)
        #expect(pending.sessionNotice == nil)
        let projected = UserText(id: UserText.stableId(localId: pending.localId), text: pending.text, createdAt: pending.createdAt,
                                 localId: pending.localId, isPending: true, files: pending.files, sessionMessageOrigin: origin)
        var transcript = Transcript()
        transcript.apply([TranscriptMessage(id: "server-row", seq: 7, localId: pending.localId, createdAt: pending.createdAt, record: raw)])
        guard case .userText(let committed)? = transcript.items.first else { Issue.record("missing committed"); return }
        #expect(committed.id == projected.id && committed.id == "local:message-local")
        #expect(committed.seq == 7 && !committed.isPending)
        #expect(committed.text == projected.text && committed.text == text)
        #expect(committed.sessionMessageOrigin == projected.sessionMessageOrigin && committed.sessionNotice == nil)
        let edited = PendingMessage.editedRecord(raw, text: "Edited text")
        #expect(edited["content"]?["text"] == "Edited text")
        #expect(edited["meta"]?["happier"] == raw["meta"]?["happier"])
        #expect(SessionMessageOrigin.parse(edited["meta"]) == origin)
        #expect(MessageSelection.clipboardText([.userText(projected), .userText(committed)], agentName: "Claude") == text + "\n\n" + text)
        let attached = UserText(id: "file", text: text, createdAt: .now, localId: nil, isPending: false,
                                files: [MessageAttachment(name: "photo.png")], sessionMessageOrigin: origin)
        #expect(attached.attachments == ["photo.png"] && attached.sessionMessageOrigin == origin && attached.sessionNotice == nil)
        #expect(MessageSelection.isSelectable(.userText(attached)))
    }

    @Test func explicitOriginWinsWhenMessageQuotesCompleteAutomaticNotice() throws {
        let text = SessionNoticeTests.vectors[0]["text"]!.stringValue!
        #expect(SessionNotice.parse(text) != nil)
        let raw = record(text: text, meta: Self.record["meta"])
        var transcript = Transcript()
        transcript.apply([row("quoted-notice", record: raw)])
        guard case .userText(let message)? = transcript.items.first else { Issue.record("missing message"); return }
        #expect(message.sessionMessageOrigin != nil && message.sessionNotice == nil)
        #expect(message.text == text && MessageSelection.isSelectable(.userText(message)))
        #expect(MessageSelection.clipboardText([.userText(message)], agentName: "Claude") == text)
        let queueRow: JSONValue = ["localId": "quoted-local", "content": ["t": "plain", "v": raw], "status": "queued", "position": 1, "createdAt": 1000]
        let pending = try #require(PendingMessage.list([queueRow], session: plainSession()).first)
        #expect(pending.sessionMessageOrigin == message.sessionMessageOrigin && pending.sessionNotice == nil)
        // Without the explicit envelope the same known text remains the existing lineage notice.
        var legacy = Transcript()
        legacy.apply([row("legacy", record: record(text: text, meta: nil))])
        guard case .userText(let notice)? = legacy.items.first else { Issue.record("missing notice"); return }
        #expect(notice.sessionNotice != nil && notice.sessionMessageOrigin == nil)
    }

    @Test func distinctSessionsAreDifferentSpeakersAndAgentRoleCannotClaimOrigin() throws {
        let first = try #require(SessionMessageOrigin.parse(Self.record["meta"]))
        let otherMeta: JSONValue = ["happier": ["kind": "session_message.v1", "payload": ["senderSessionId": "another-full-session-id", "targetSessionId": "c123456789012345678901234"]]]
        let second = try #require(SessionMessageOrigin.parse(otherMeta))
        let a = ChatItem.userText(UserText(id: "one", text: "First", createdAt: .now, localId: nil, isPending: false, sessionMessageOrigin: first))
        let b = ChatItem.userText(UserText(id: "two", text: "Second", createdAt: .now, localId: nil, isPending: false, sessionMessageOrigin: second))
        #expect(MessageSelection.clipboardText([a, b], agentName: "Claude") == "**Session c987654321098765432109876:**\n\nFirst\n\n**Session another-full-session-id:**\n\nSecond")
        let agentRaw: JSONValue = ["role": "agent", "content": ["type": "output", "data": ["type": "user", "message": ["content": "Provider echo"]]], "meta": Self.record["meta"]!]
        var transcript = Transcript()
        transcript.apply([row("agent-role", record: agentRaw)])
        guard case .userText(let echo)? = transcript.items.first else { Issue.record("missing provider echo"); return }
        #expect(echo.sessionMessageOrigin == nil)
        let queueRow: JSONValue = ["localId": "agent-row", "content": ["t": "plain", "v": agentRaw], "status": "queued", "position": 1, "createdAt": 1000]
        let session = try plainSession()
        #expect(PendingMessage.list([queueRow], session: session).first?.sessionMessageOrigin == nil)
    }

    private func record(text: String, meta: JSONValue?) -> JSONValue {
        ["role": "user", "content": ["type": "text", "text": .string(text)], "meta": meta ?? .null]
    }

    private func row(_ id: String, record: JSONValue) -> TranscriptMessage {
        TranscriptMessage(id: id, seq: 1, localId: nil, createdAt: .now, record: record)
    }

    private func plainSession() throws -> Session {
        try Session(row: ["id": "session", "seq": 0, "createdAt": 1, "updatedAt": 1, "active": true, "activeAt": 1,
                          "encryptionMode": "plain", "metadata": "{}", "metadataVersion": 1, "agentStateVersion": 0], keys: nil)
    }

}

import Foundation
import Testing
@testable import HappierKit

@Suite struct SessionDraftTests {
    @Test func aNewDraftHasTheOfficialShape() throws {
        let payload = SessionDraft.payload(sessionId: "s1", document: SessionDraft.document(text: "hola"))
        #expect(payload["v"]?.intValue == 1)
        #expect(payload["address"] == ["kind": "session", "sessionId": "s1"])
        let document = try #require(payload["document"])
        #expect(document["v"]?.intValue == 1)
        #expect(document["composer"]?["text"]?["value"]?.stringValue == "hola")
        #expect(document["composer"]?["mentions"]?["value"] == .array([]))
        #expect(document["composer"]?["attachments"]?["value"] == .array([]))
        #expect(document["target"]?["kind"]?.stringValue == "session")
        for field in ["recipient", "agentContinuation", "executionRunDelivery"] {
            #expect(document["target"]?["routing"]?[field]?["value"] == .null)
            #expect(UUID(uuidString: document["target"]?["routing"]?[field]?["mutationId"]?.stringValue ?? "") != nil)
        }
        #expect(document["extensions"] == .object([:]))
    }

    @Test func editingTheTextKeepsEverythingElse() throws {
        var original = SessionDraft.document(text: "first")
        original = SessionDraft.setting(["kind": "file", "path": "a.swift"], at: ["composer", "mentions"], in: original)
        let edited = SessionDraft.withText("second", in: original)
        #expect(SessionDraft.text(of: edited) == "second")
        #expect(edited["composer"]?["mentions"] == original["composer"]?["mentions"])
        #expect(edited["composer"]?["text"]?["mutationId"] != original["composer"]?["text"]?["mutationId"])
        #expect(SessionDraft.withText("second", in: edited) == edited)
    }

    @Test func meaningfulMeansSomethingToResume() {
        #expect(!SessionDraft.isMeaningful(SessionDraft.document(text: "  \n")))
        #expect(SessionDraft.isMeaningful(SessionDraft.document(text: "hola")))
    }

    @Test func readsRecordsAndMutationOutcomes() throws {
        let present = SessionDraft.Record(response: ["status": "present", "record": [
            "address": "session/s1", "revision": 4, "content": ["t": "plain", "v": [:]], "createdAt": 1, "updatedAt": 2,
        ]])
        #expect(present?.revision == 4 && present?.content != nil)
        let deleted = SessionDraft.Record(response: ["status": "deleted", "record": [
            "address": "session/s1", "revision": 5, "content": .null, "createdAt": 1, "updatedAt": 3,
        ]])
        #expect(deleted?.revision == 5 && deleted?.content == nil)
        #expect(SessionDraft.Record(response: ["status": "absent"]) == nil)

        #expect(SessionDraft.Outcome(response: ["status": "updated", "record": ["revision": 6, "content": .null, "updatedAt": 1]]) == .updated(revision: 6))
        #expect(SessionDraft.Outcome(response: ["status": "conflict", "current": ["status": "absent"]]) == .conflict(revision: nil))
        #expect(SessionDraft.Outcome(response: ["status": "conflict", "current": ["revision": 9, "content": .null, "updatedAt": 1]]) == .conflict(revision: 9))
    }

    @Test func aPayloadOpensOnlyForItsOwnSession() {
        let document = SessionDraft.document(text: "hola")
        let payload = SessionDraft.payload(sessionId: "s1", document: document)
        #expect(SessionDraft.document(fromPayload: payload, sessionId: "s1") == document)
        #expect(SessionDraft.document(fromPayload: payload, sessionId: "s2") == nil)
    }
}

import Foundation
import Testing
@testable import HappierKit

struct NewSessionDraftTests {
    private func session(_ id: String, machine: String? = "mac-a", path: String? = "/work/app", parent: String? = nil) throws -> Session {
        var metadata: [String: JSONValue] = ["summary": ["text": .string(id)]]
        if let machine { metadata["machineId"] = .string(machine) }
        if let path { metadata["path"] = .string(path) }
        if let parent { metadata["listParentV1"] = ["v": 1, "parentSessionId": .string(parent)] }
        return try Session(row: ["id": .string(id), "seq": 1, "createdAt": 1, "updatedAt": 1,
                                 "active": false, "encryptionMode": "plain", "metadataVersion": 1,
                                 "metadata": .string(String(decoding: try JSONValue.object(metadata).encoded(), as: UTF8.self))], keys: nil)
    }

    @Test func aFolderDraftKeepsTheExactSessionsMachineAndDirectory() throws {
        let source = try session("old", machine: "offline-mac", path: "/work/app/subfolder")
        let draft = try #require(NewSessionDraft(inFolderOf: source))
        #expect(draft.machineId == "offline-mac")
        #expect(draft.directory == "/work/app/subfolder")
        #expect(draft.group == nil)
        #expect(try NewSessionDraft(inFolderOf: session("unknown", machine: nil)) == nil)
        #expect(try NewSessionDraft(inFolderOf: session("unknown", path: nil)) == nil)
    }

    @Test func aGroupDraftUsesTheSharedFolderOnTheTargetsMachine() throws {
        let target = try session("target", path: "/work/app/one", parent: "grandparent")
        let dragged = try session("dragged", path: "/work/app/two")
        let draft = try #require(NewSessionDraft(grouping: dragged, with: target))
        #expect(draft.machineId == "mac-a")
        #expect(draft.directory == "/work/app")
        #expect(draft.group?.targetId == "target")
        #expect(draft.group?.draggedId == "dragged")
        #expect(draft.group?.suggestedTitle == "target + dragged")
        // Preparing or cancelling the assistant does not move either original session.
        #expect(target.parentSessionId == "grandparent")
        #expect(dragged.parentSessionId == nil)
    }

    @Test func differentMachinesOrUnrelatedFoldersKeepTheTargetsFolder() throws {
        let target = try session("target", machine: "mac-a", path: "/work/app/one")
        let remote = try session("remote", machine: "mac-b", path: "/work/app/two")
        #expect(NewSessionDraft(grouping: remote, with: target)?.directory == "/work/app/one")
        let unrelated = try session("other", path: "/opt/other")
        #expect(NewSessionDraft(grouping: unrelated, with: target)?.directory == "/work/app/one")
    }

    @MainActor @Test func failedParentCreationDoesNotMoveTheOriginalSessions() async throws {
        let store = HappierStore(server: URL(string: "http://127.0.0.1:1")!)
        store.phase = .signedOut
        let target = try session("target", parent: "grandparent")
        let dragged = try session("dragged")
        store.sessions[target.id] = target
        store.sessions[dragged.id] = dragged
        let draft = try #require(NewSessionDraft(grouping: dragged, with: target))
        let outcome = await store.createSession(machineId: draft.machineId, directory: draft.directory,
                                                agentId: "codex", permissionMode: .yolo, modelId: "chosen-model",
                                                firstMessage: "Review both", grouping: draft.group, title: "My group")
        guard case .failed = outcome else { Issue.record("A signed-out store must not create a parent"); return }
        #expect(store.sessions[target.id]?.parentSessionId == "grandparent")
        #expect(store.sessions[dragged.id]?.parentSessionId == nil)
        #expect(store.openRequest == nil)
    }
}

import Foundation
import Testing
@testable import HappierKit

/// Who may delete a session for good (`sessionActionContext.ts` `canDelete`): its owner, once it
/// has stopped and no preserved terminal host still holds it.
@Suite struct SessionDeletionTests {
    private func session(active: Bool = false, share: JSONValue? = nil, terminal: JSONValue? = nil) throws -> Session {
        var metadata: [String: JSONValue] = ["path": "/p"]
        if let terminal { metadata["terminal"] = ["controlServiceabilityV1": terminal] }
        var row: [String: JSONValue] = [
            "id": "s1", "seq": 1, "createdAt": 1, "updatedAt": 2, "active": .bool(active),
            "encryptionMode": "plain", "metadata": .string(String(decoding: try JSONValue.object(metadata).encoded(), as: UTF8.self)),
            "metadataVersion": 1,
        ]
        if let share { row["share"] = share }
        return try Session(row: .object(row), keys: nil)
    }

    @Test func ownStoppedSessionsCanBeDeleted() throws {
        #expect(try session().canDelete)
        #expect(try session(share: .null).canDelete)
    }

    @Test func runningSessionsMustBeStoppedFirst() throws {
        #expect(try !session(active: true).canDelete)
    }

    @Test func sessionsSharedWithTheUserAreNeverDeletable() throws {
        for level in ["view", "edit", "admin"] {
            #expect(try !session(share: ["accessLevel": .string(level), "canApprovePermissions": true]).canDelete)
        }
    }

    @Test func aPreservedTerminalHostBlocksDeletionButARetiredOneDoesNot() throws {
        #expect(try !session(terminal: ["v": 1, "state": "servable", "attachmentId": "a1"]).canDelete)
        #expect(try session(terminal: ["v": 1, "retired": true]).canDelete)
        #expect(try session(terminal: ["v": 2]).canDelete)
    }
}

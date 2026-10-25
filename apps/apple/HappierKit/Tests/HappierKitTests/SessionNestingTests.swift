import Foundation
import Testing
@testable import HappierKit

/// Where the session list nests a session: under the session that started it, unless it was moved
/// by dropping it on another (`listParentV1`).
@Suite struct SessionNestingTests {
    private func session(_ id: String, _ metadata: JSONValue) throws -> Session {
        try Session(row: ["id": .string(id), "seq": 1, "createdAt": 1, "updatedAt": 1, "active": false, "encryptionMode": "plain",
                          "metadata": .string(String(decoding: try metadata.encoded(), as: UTF8.self)), "metadataVersion": 1], keys: nil)
    }

    @Test func aMoveOverridesTheSessionThatStartedIt() throws {
        let spawned: JSONValue = ["spawnedBySessionV1": ["v": 1, "parentSessionId": "p"]]
        #expect(try session("c", spawned).parentSessionId == "p")
        let moved = MetadataEdit.setListParent("q", in: spawned, now: 5)
        #expect(try session("c", moved).parentSessionId == "q")
        // Taken out of its parent: top level, not back under the one that started it.
        let detached = MetadataEdit.setListParent(nil, in: moved, now: 6)
        #expect(try session("c", detached).parentSessionId == nil)
    }

    @Test func aSessionCantGoUnderItselfOrUnderItsOwnSessions() {
        let parents = ["b": "a", "c": "b"]
        #expect(SessionTree.canNest("a", under: "z", parent: { parents[$0] }))
        #expect(SessionTree.canNest("c", under: "a", parent: { parents[$0] }))
        #expect(!SessionTree.canNest("a", under: "a", parent: { parents[$0] }))
        #expect(!SessionTree.canNest("a", under: "c", parent: { parents[$0] }))
    }

    @Test func aParentForTwoSessionsStartsInTheFolderTheyShare() {
        #expect(SessionTree.sharedFolder("/Users/m/Projects/agilgob/nilo-saas", "/Users/m/Projects/agilgob/expedient-docs") == "/Users/m/Projects/agilgob")
        #expect(SessionTree.sharedFolder("/Users/m/Projects/radar", "/Users/m/Projects/radar") == "/Users/m/Projects/radar")
        #expect(SessionTree.sharedFolder("/Users/m/one", "/Users/manny/two") == "/Users")
        #expect(SessionTree.sharedFolder("/Users/m/a", "/opt/b") == nil)
        #expect(SessionTree.sharedFolder("C:\\work\\one", "C:\\work\\two") == "C:\\work")
    }
}

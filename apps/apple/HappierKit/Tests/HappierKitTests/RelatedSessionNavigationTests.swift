import Foundation
import Testing
@testable import HappierKit

@MainActor
@Suite struct RelatedSessionNavigationTests {
    @Test func knownSessionOpensFromCacheWithoutAuthenticationOrClearingOtherError() async throws {
        let store = HappierStore(server: URL(string: "http://127.0.0.1:1")!)
        let session = try Session(row: ["id": "cached-related", "seq": 0, "createdAt": 1, "updatedAt": 1,
                                        "active": false, "activeAt": 1, "encryptionMode": "plain", "metadata": "{}",
                                        "metadataVersion": 1, "agentStateVersion": 0], keys: nil)
        store.sessions[session.id] = session
        store.lastError = "An unrelated error"
        await store.openRelatedSession(session.id)
        #expect(store.openRequest == session.id)
        #expect(store.sessions[session.id] == session)
        #expect(store.lastError == "An unrelated error")
    }

    @Test func unknownSessionWithoutConnectionReportsErrorWithoutNavigating() async {
        let store = HappierStore(server: URL(string: "http://127.0.0.1:1")!)
        store.openRequest = "previous-navigation"
        await store.openRelatedSession("missing-related")
        #expect(store.lastError == "Connect to load this session.")
        #expect(store.openRequest == "previous-navigation")
        #expect(store.sessions["missing-related"] == nil)
    }
}

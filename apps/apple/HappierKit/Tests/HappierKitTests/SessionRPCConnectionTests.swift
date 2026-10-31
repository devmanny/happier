import Foundation
import Testing
@testable import HappierKit

/// Coming back to the app (from the share sheet, a notification) the relay connection takes a
/// moment to return. A call made meanwhile, like uploading shared files, waits for it within its
/// own time budget instead of failing at once with "Not connected".
@MainActor
struct SessionRPCConnectionTests {
    @Test func waitsForTheConnectionWithinItsTimeoutBeforeGivingUp() async {
        let store = HappierStore(server: URL(string: "http://127.0.0.1:1")!)
        store.phase = .ready
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: HappierStore.RPCError.self) {
            _ = try await store.sessionRPC("s1", method: "ping", params: [:], timeout: .milliseconds(400))
        }
        #expect(clock.now - started >= .milliseconds(350))
    }

    @Test func signedOutThereIsNothingToWaitFor() async {
        let store = HappierStore(server: URL(string: "http://127.0.0.1:1")!)
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: HappierStore.RPCError.self) {
            _ = try await store.sessionRPC("s1", method: "ping", params: [:], timeout: .seconds(5))
        }
        #expect(clock.now - started < .seconds(1))
    }
}

import Foundation
import Testing
@testable import HappierKit

/// Opt-in checks against a real Happier server: `HAPPIER_LIVE_SERVER=https://api.happier.dev swift test`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HAPPIER_LIVE_SERVER"] != nil))
struct LiveServerTests {
    let server = URL(string: ProcessInfo.processInfo.environment["HAPPIER_LIVE_SERVER"] ?? "https://api.happier.dev")!

    @Test func socketHandshakeRejectsInvalidToken() async throws {
        let client = SocketIOClient(
            serverURL: server, path: "/v1/updates",
            auth: ["token": "invalid-token", "clientType": "user-scoped"]
        )
        let error = await #expect(throws: SocketIOClient.ConnectError.self) { try await client.connect() }
        // A namespace-level rejection (Socket.IO "44"), not a transport failure.
        #expect(error?.message.hasPrefix("connect error") == false)
    }

    @Test func accountLinkRequestIsAcceptedAndPending() async throws {
        let auth = AuthAPI(server: server)
        let pair = try await auth.startAccountLink()
        let poll = Task { try await auth.waitForApproval(pair) }
        try await Task.sleep(for: .seconds(2.5))
        poll.cancel()
        // Still waiting (no approval) means both the request and the v2 poll shape were accepted.
        await #expect(throws: CancellationError.self) { try await poll.value }
    }
}

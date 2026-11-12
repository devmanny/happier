import Foundation
import Testing
@testable import HappierKit

/// After the computer restarts, the relay keeps showing its sessions as running until their
/// presence timeout runs out, and a stop finds no process to ask. Stop then ends such a session
/// at once (`session-end`), and only when the relay has no runner connected for it.
@MainActor @Suite(.serialized)
struct DeadSessionStopTests {
    @Test func stoppingASessionWhoseProcessIsGoneEndsItAndArchivesIt() async throws {
        let relay = DeadRunnerRelay()
        let store = try relay.store()
        await store.confirmStop(.init(sessionId: "s1", thenArchive: true))
        #expect(relay.endedSessions == ["s1"])
        #expect(store.sessions["s1"]?.active == false)
        #expect(store.sessions["s1"]?.archivedAt != nil)
        #expect(store.lastError == nil)
    }

    @Test func stopWhileTheAgentLooksBusyEndsASessionWithNoRunner() async throws {
        let relay = DeadRunnerRelay()
        let store = try relay.store()
        #expect(store.sessions["s1"]?.status(heartbeats: false) == .working)
        await store.abort("s1")
        #expect(relay.endedSessions == ["s1"])
        #expect(store.sessions["s1"]?.status() == .offline)
        #expect(store.lastError == nil)
    }

    @Test func aConnectedRunnerIsNeverEnded() async throws {
        // A connected runner that doesn't implement the method answers RPC_METHOD_NOT_FOUND.
        let relay = DeadRunnerRelay(runnerError: "RPC_METHOD_NOT_FOUND")
        let store = try relay.store()
        await store.abort("s1")
        await store.confirmStop(.init(sessionId: "s1", thenArchive: false))
        #expect(relay.endedSessions.isEmpty)
        #expect(store.sessions["s1"]?.active == true)
    }

    @Test func anEndTheRelayDoesNotApplyIsReported() async throws {
        let relay = DeadRunnerRelay(appliesEnd: false)
        let store = try relay.store()
        await store.confirmStop(.init(sessionId: "s1", thenArchive: true))
        #expect(relay.endedSessions == ["s1"])
        #expect(store.sessions["s1"]?.active == true)
        #expect(store.sessions["s1"]?.archivedAt == nil)
        #expect(store.lastError != nil)
    }
}

/// The relay after a restart: the session still marked active, its machine's daemon online but
/// not running it, and no runner connected for it.
private final class DeadRunnerRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let runnerError: String
    private let appliesEnd: Bool
    private var active = true
    private var ended: [String] = []
    private let lastSeenMs = (Date.now.timeIntervalSince1970 - 60) * 1000

    init(runnerError: String = "RPC_METHOD_NOT_AVAILABLE", appliesEnd: Bool = true) {
        self.runnerError = runnerError
        self.appliesEnd = appliesEnd
    }

    var endedSessions: [String] { lock.withLock { ended } }

    @MainActor func store() throws -> HappierStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeadRunnerURLProtocol.self]
        DeadRunnerURLProtocol.relay = self
        let api = HappierAPI(server: URL(string: "https://relay.invalid")!, token: "t", session: URLSession(configuration: configuration))
        let store = HappierStore(server: URL(string: "https://relay.invalid")!)
        store.installForTesting(api: api, keys: try AccountKeys(masterSecret: Data(0..<32)),
                                snapshotDirectory: FileManager.default.temporaryDirectory.appending(path: "dead-runner-\(UUID().uuidString)")) { [self] event, payload in
            socketAck(event, payload)
        }
        store.sessions["s1"] = try Session(row: sessionRow(), keys: nil)
        return store
    }

    private func sessionRow() -> JSONValue {
        let metadata = #"{"machineId":"m1","path":"/work","flavor":"claude"}"#
        return lock.withLock {
            ["id": "s1", "seq": 3, "encryptionMode": "plain", "metadata": .string(metadata),
             "active": .bool(active), "activeAt": .number(lastSeenMs), "thinking": .bool(active),
             "thinkingAt": .number(lastSeenMs), "latestTurnStatus": active ? "in_progress" : "cancelled",
             "latestTurnStatusObservedAt": .number(lastSeenMs)]
        }
    }

    private func socketAck(_ event: String, _ payload: JSONValue) -> [JSONValue] {
        if event == "session-end" {
            lock.withLock {
                ended.append(payload["sid"]?.stringValue ?? "")
                // `applyReleasedUiV021SessionEnd.ts` ignores an end older than the last activity.
                if appliesEnd, (payload["time"]?.doubleValue ?? 0) >= lastSeenMs { active = false }
            }
            return []
        }
        switch payload["method"]?.stringValue {
        case "m1:stop-session": return [["ok": true, "result": ["status": "not_found"]]]
        case "s1:killSession", "s1:abort": return [["ok": false, "error": "RPC method not available", "errorCode": .string(runnerError)]]
        default: return [["ok": false, "error": .string("unexpected \(event)")]]
        }
    }

    func respond(_ request: URLRequest) -> (Int, JSONValue) {
        switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
        case ("GET", "/v1/machines/m1"):
            let plain = Data(#"{"t":"plain"}"#.utf8).base64EncodedString()
            return (200, ["machine": ["id": "m1", "active": true, "dataEncryptionKey": .string(plain)]])
        case ("GET", "/v2/sessions/s1"):
            return (200, ["session": sessionRow()])
        case ("POST", "/v2/sessions/s1/archive"):
            return lock.withLock { active } ? (409, ["error": "session_active"]) : (200, ["success": true])
        default:
            return (404, ["error": "not found"])
        }
    }
}

private final class DeadRunnerURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var relay: DeadRunnerRelay?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, json) = Self.relay?.respond(request) ?? (500, ["error": "no relay"])
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? json.encoded()) ?? Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

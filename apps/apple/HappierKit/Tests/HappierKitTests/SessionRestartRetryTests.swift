import Foundation
import Testing
@testable import HappierKit

/// A message paused because the session's terminal never became usable: retrying it alone goes
/// back to the same terminal. Restart-and-retry stops the session, resumes it and queues the
/// message again, in that order.
@MainActor @Suite(.serialized)
struct SessionRestartRetryTests {
    @Test func stopsTheSessionResumesItAndQueuesTheMessageAgain() async throws {
        let relay = StuckTerminalRelay()
        let store = try relay.store()
        await store.restartSessionAndRetry("p1", in: "s1")
        #expect(relay.steps == ["stop", "resume", "requeue"])
        #expect(store.restartingSessions.isEmpty)
        #expect(store.lastError == nil)
    }

    @Test func aSessionThatCouldNotBeStoppedIsLeftAsItWas() async throws {
        let relay = StuckTerminalRelay(stopResult: ["status": "incomplete", "reason": "runner_exit_timeout"])
        let store = try relay.store()
        await store.restartSessionAndRetry("p1", in: "s1")
        #expect(relay.steps == ["stop"])
        #expect(store.lastError != nil)
        #expect(store.restartingSessions.isEmpty)
    }
}

/// A relay with one running session whose daemon answers stop and resume.
private final class StuckTerminalRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let stopResult: JSONValue
    private var active = true
    private var recorded: [String] = []

    init(stopResult: JSONValue = ["status": "stopped"]) { self.stopResult = stopResult }

    var steps: [String] { lock.withLock { recorded } }

    @MainActor func store() throws -> HappierStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StuckTerminalURLProtocol.self]
        StuckTerminalURLProtocol.relay = self
        let api = HappierAPI(server: URL(string: "https://relay.invalid")!, token: "t", session: URLSession(configuration: configuration))
        let store = HappierStore(server: URL(string: "https://relay.invalid")!)
        store.installForTesting(api: api, keys: try AccountKeys(masterSecret: Data(0..<32)),
                                snapshotDirectory: FileManager.default.temporaryDirectory.appending(path: "stuck-terminal-\(UUID().uuidString)")) { [self] _, payload in
            socketAck(payload)
        }
        store.sessions["s1"] = try Session(row: sessionRow(), keys: nil)
        return store
    }

    private func sessionRow() -> JSONValue {
        let metadata = #"{"machineId":"m1","path":"/work","flavor":"claude","claudeSessionId":"thread"}"#
        return lock.withLock {
            ["id": "s1", "seq": 3, "encryptionMode": "plain", "metadata": .string(metadata), "active": .bool(active),
             "activeAt": .number(Date.now.timeIntervalSince1970 * 1000), "latestTurnStatus": "failed"]
        }
    }

    private func socketAck(_ payload: JSONValue) -> [JSONValue] {
        switch payload["method"]?.stringValue {
        case "m1:stop-session":
            return lock.withLock {
                recorded.append("stop")
                if stopResult["status"]?.stringValue == "stopped" { active = false }
                return [["ok": true, "result": stopResult]]
            }
        case "m1:spawn-happy-session":
            return lock.withLock {
                // Resuming a session that still runs would only reattach the stuck terminal.
                recorded.append(active ? "resume-while-running" : "resume")
                active = true
                return [["ok": true, "result": ["type": "success", "sessionId": "s1"]]]
            }
        default:
            return [["ok": false, "error": "unexpected"]]
        }
    }

    func respond(_ request: URLRequest) -> (Int, JSONValue) {
        switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
        case ("GET", "/v1/machines/m1"):
            let plain = Data(#"{"t":"plain"}"#.utf8).base64EncodedString()
            return (200, ["machine": ["id": "m1", "active": true, "dataEncryptionKey": .string(plain)]])
        case ("GET", "/v2/sessions/s1"):
            return (200, ["session": sessionRow()])
        case ("PATCH", "/v2/sessions/s1/pending/p1/action"):
            lock.withLock { recorded.append("requeue") }
            return (200, ["success": true])
        case ("GET", "/v2/sessions/s1/pending"):
            return (200, ["pending": []])
        default:
            return (404, ["error": "not found"])
        }
    }
}

private final class StuckTerminalURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var relay: StuckTerminalRelay?

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

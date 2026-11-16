import Foundation
import Testing
@testable import HappierKit

/// A queued message the runner holds back because text is open in Claude's terminal composer
/// (`terminal_composer_draft`): Clear Terminal Draft asks the runner to empty that composer
/// (`session.terminalComposer.clear`). The runner sends the held messages itself afterwards, so
/// the app never puts them back in line.
@MainActor @Suite(.serialized)
struct TerminalDraftClearTests {
    @Test func readsWhatTheRunnerDidFromItsStatus() {
        let cases: [(String, TerminalDraftClear.Outcome)] = [
            ("cleared", .cleared),
            ("already_empty", .nothingToClear),
            ("generating", .working),
            ("dialog_open", .dialogOpen),
            ("not_safe", .notSafe),
            ("clear_failed", .notCleared),
            ("no_live_terminal", .unreachable),
            ("host_dead", .unreachable),
            ("unsupported", .unsupported),
            ("capture_unavailable", .unsupported),
            ("a_status_from_a_newer_runner", .notCleared),
        ]
        for (status, outcome) in cases {
            let ok = status == "cleared" || status == "already_empty"
            // The runner's own reason (`errorCode`) never decides the outcome.
            let result: JSONValue = ["ok": .bool(ok), "status": .string(status), "errorCode": "permission_prompt"]
            #expect(TerminalDraftClear.outcome(result) == outcome, "status \(status)")
        }
        #expect(TerminalDraftClear.Outcome.cleared.message == nil)
        #expect(TerminalDraftClear.Outcome.nothingToClear.message != nil)
    }

    @Test func readsRelayFailures() {
        #expect(TerminalDraftClear.outcome(error: HappierStore.RPCError(message: "no runner", code: "RPC_METHOD_NOT_AVAILABLE")) == .unreachable)
        #expect(TerminalDraftClear.outcome(error: HappierStore.RPCError(message: "unknown method", code: "RPC_METHOD_NOT_FOUND")) == .unsupported)
        #expect(TerminalDraftClear.outcome(error: HappierStore.RPCError(message: "Empty RPC response", code: nil)) == .failed("Empty RPC response"))
        #expect(TerminalDraftClear.outcome(error: URLError(.timedOut)) == .failed(UserFacingError.timedOut))
    }

    /// Offered only when the session's runner says it can clear its terminal; older runners say nothing.
    @Test func offeredOnlyWhenTheRunnerSupportsIt() throws {
        func session(_ capabilities: JSONValue?) throws -> Session {
            var session = try Session(row: ["id": "s1", "seq": 1, "encryptionMode": "plain", "metadata": #"{"path":"/a"}"#,
                                            "metadataVersion": 1, "agentStateVersion": 1], keys: nil)
            if let capabilities { session.agentState = ["capabilities": capabilities] }
            return session
        }
        #expect(try !session(nil).terminalDraftClearSupported)
        #expect(try !session(["inFlightSteerSupported": true]).terminalDraftClearSupported)
        #expect(try !session(["terminalComposerClearSupported": false]).terminalDraftClearSupported)
        #expect(try session(["terminalComposerClearSupported": true]).terminalDraftClearSupported)
    }

    /// The runner sends the held message itself once its composer is empty: whatever it answers,
    /// the blocked row is not put back in line from here (that would send it twice), and the
    /// queue is read again to show what the runner did.
    @Test(arguments: [("cleared", TerminalDraftClear.Outcome.cleared), ("already_empty", .nothingToClear)])
    func asksTheSessionsRunnerAndLeavesTheQueueAlone(status: String, outcome: TerminalDraftClear.Outcome) async throws {
        let relay = TerminalDraftRelay(ack: [["ok": true, "result": ["ok": true, "status": .string(status), "sessionId": "s1"]]])
        let store = try await relay.storeHoldingABlockedMessage()
        #expect(await store.clearTerminalDraft(in: "s1") == outcome)
        #expect(relay.calls == [TerminalDraftRelay.Call(method: "s1:session.terminalComposer.clear", params: ["sessionId": "s1"])])
        #expect(relay.clearingDuringCall == [true])
        #expect(try await relay.queueReadAfterCall())
        #expect(relay.pendingMutations.isEmpty)
        #expect(store.clearingTerminalDrafts.isEmpty)
        #expect(store.lastError == nil)
    }

    /// A refusal is the runner's answer, not a transport failure: its status says why.
    @Test func aRefusalSaysWhy() async throws {
        let relay = TerminalDraftRelay(ack: [["ok": true, "result": [
            "ok": false, "status": "generating", "sessionId": "s1", "errorCode": "generating",
            "error": "terminal_composer_clear_refused:generating",
        ]]])
        let store = try await relay.storeHoldingABlockedMessage()
        #expect(await store.clearTerminalDraft(in: "s1") == .working)
        #expect(try await relay.queueReadAfterCall())
        #expect(relay.pendingMutations.isEmpty)
        #expect(store.clearingTerminalDrafts.isEmpty)
        #expect(store.lastError == nil)
    }

    @Test func noConnectedRunnerIsUnreachable() async throws {
        let relay = TerminalDraftRelay(ack: [["ok": false, "error": "RPC method not available", "errorCode": "RPC_METHOD_NOT_AVAILABLE"]])
        let store = try await relay.storeHoldingABlockedMessage()
        #expect(await store.clearTerminalDraft(in: "s1") == .unreachable)
        #expect(try await relay.queueReadAfterCall())
        #expect(relay.pendingMutations.isEmpty)
        #expect(store.clearingTerminalDrafts.isEmpty)
        #expect(store.lastError == nil)
    }

    /// A connected runner without the method answers through the relay with its RPC layer's error
    /// (`RpcHandlerManager`), not with a clear result.
    @Test func aRunnerWithoutTheMethodCantClear() async throws {
        let relay = TerminalDraftRelay(ack: [["ok": true, "result": ["error": "Method not found", "errorCode": "RPC_METHOD_NOT_FOUND"]]])
        let store = try await relay.storeHoldingABlockedMessage()
        #expect(await store.clearTerminalDraft(in: "s1") == .unsupported)
        #expect(try await relay.queueReadAfterCall())
        #expect(relay.pendingMutations.isEmpty)
    }
}

/// A relay with one running plain session whose queue holds one message the runner blocked on a
/// terminal draft (`p1`, `terminal_composer_draft`): answers its RPC calls with `ack` and records
/// any change to that queue and any read of it after the call.
private final class TerminalDraftRelay: @unchecked Sendable {
    struct Call: Equatable {
        let method: String
        let params: JSONValue
    }

    private let lock = NSLock()
    private let ack: [JSONValue]
    private var recordedCalls: [Call] = []
    private var recordedMutations: [String] = []
    private var recordedClearing: [Bool] = []
    private var readsAfterCall = 0
    @MainActor private weak var installed: HappierStore?

    init(ack: [JSONValue]) { self.ack = ack }

    var calls: [Call] { lock.withLock { recordedCalls } }
    var pendingMutations: [String] { lock.withLock { recordedMutations } }
    /// Whether the store showed the clear in flight while the runner was asked.
    var clearingDuringCall: [Bool] { lock.withLock { recordedClearing } }

    /// The store with the blocked message already on screen, as when the button is tapped.
    @MainActor func storeHoldingABlockedMessage() async throws -> HappierStore {
        let store = try store()
        store.refreshPending("s1")
        try await waitUntil { store.pendingQueues["s1"]?.map(\.state) == [.blocked(reason: "terminal_composer_draft")] }
        return store
    }

    /// Whether the store read the queue again once the runner had answered.
    func queueReadAfterCall() async throws -> Bool {
        try await waitUntil { self.lock.withLock { self.readsAfterCall > 0 } }
        return true
    }

    private func waitUntil(_ condition: @escaping @MainActor @Sendable () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(5)
        while await !MainActor.run(body: condition) {
            guard Date.now < deadline else { throw WaitTimedOut() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor private func store() throws -> HappierStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TerminalDraftURLProtocol.self]
        TerminalDraftURLProtocol.relay = self
        let api = HappierAPI(server: URL(string: "https://relay.invalid")!, token: "t", session: URLSession(configuration: configuration))
        let store = HappierStore(server: URL(string: "https://relay.invalid")!)
        store.installForTesting(api: api, keys: try AccountKeys(masterSecret: Data(0..<32)),
                                snapshotDirectory: FileManager.default.temporaryDirectory.appending(path: "terminal-draft-\(UUID().uuidString)")) { [self] event, payload in
            await socketAck(event, payload)
        }
        store.sessions["s1"] = try Session(row: [
            "id": "s1", "seq": 3, "encryptionMode": "plain", "metadata": #"{"machineId":"m1","path":"/work","flavor":"claude"}"#,
            "active": true, "activeAt": .number(Date.now.timeIntervalSince1970 * 1000),
        ], keys: nil)
        installed = store
        return store
    }

    private func socketAck(_ event: String, _ payload: JSONValue) async -> [JSONValue] {
        guard event == "rpc-call" else { return [["ok": false, "error": .string("unexpected \(event)")]] }
        let clearing = await MainActor.run { installed?.clearingTerminalDrafts.contains("s1") ?? false }
        lock.withLock {
            recordedCalls.append(Call(method: payload["method"]?.stringValue ?? "", params: payload["params"] ?? .null))
            recordedClearing.append(clearing)
        }
        return ack
    }

    func respond(_ request: URLRequest) -> (Int, JSONValue) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        switch (method, path) {
        case ("GET", "/v2/sessions/s1/pending"):
            lock.withLock { if !recordedCalls.isEmpty { readsAfterCall += 1 } }
            let record: JSONValue = ["role": "user", "content": ["type": "text", "text": "run the tests"]]
            return (200, ["pending": [[
                "localId": "p1", "content": ["t": "plain", "v": record], "status": "queued", "position": 1,
                "createdAt": 10, "updatedAt": 10, "deliveryState": "blocked", "deliveryBlockedReason": "terminal_composer_draft",
                "deliveryStatus": ["status": "blocked", "reason": "terminal_composer_draft"],
            ]]])
        default:
            if path.contains("/pending") { lock.withLock { recordedMutations.append("\(method) \(path)") } }
            return (404, ["error": "not found"])
        }
    }
}

private struct WaitTimedOut: Error {}

private final class TerminalDraftURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var relay: TerminalDraftRelay?

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

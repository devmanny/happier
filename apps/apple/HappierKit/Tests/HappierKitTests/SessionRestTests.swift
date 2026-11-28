import Foundation
import Testing
@testable import HappierKit

/// "Put to Rest" from the session list: every running session of the user's, stopped and marked
/// with the idle cleaner's rest (`sessionRestV1`) so it shows as Resting and wakes with Wake Session.
@MainActor @Suite(.serialized)
struct SessionRestTests {
    @Test func candidatesSplitIdleFromBusyAndSkipWhatIsNotTheirsToStop() throws {
        let now = Date.now
        let sessions = try [
            RestRelay.session("idle", now: now),
            RestRelay.session("failed", now: now, turn: "failed"),
            RestRelay.session("working", now: now, thinking: true, turn: "in_progress"),
            RestRelay.session("queued", now: now, pendingCount: 2),
            RestRelay.session("sending", now: now),
            RestRelay.session("stopped", now: now, active: false),
            RestRelay.session("archived", now: now, archived: true),
            RestRelay.session("shared", now: now, shared: true),
            RestRelay.session("hidden", now: now, metadata: #"{"systemSessionV1":{"hidden":true}}"#),
            RestRelay.session("terminal", now: now, agentState: #"{"controlledByUser":true}"#),
            RestRelay.session("background", now: now, extra: ["runtimeActivityState": "active", "runtimeActivityActiveCount": 1]),
            RestRelay.session("parent", now: now),
            RestRelay.session("child", now: now, thinking: true, turn: "in_progress", metadata: #"{"spawnedBySessionV1":{"parentSessionId":"parent"}}"#),
            RestRelay.session("asking", now: now, extra: ["pendingPermissionRequestCount": 1]),
            RestRelay.session("waitingParent", now: now),
            RestRelay.session("waitingChild", now: now, metadata: #"{"spawnedBySessionV1":{"parentSessionId":"waitingParent"}}"#,
                              extra: ["pendingPermissionRequestCount": 1]),
        ]
        let candidates = SessionRest.candidates(sessions, sending: ["sending"], now: now)
        #expect(Set(candidates.idle) == ["idle", "failed"])
        #expect(Set(candidates.busy) == ["working", "queued", "sending", "terminal", "background", "parent", "child", "asking", "waitingParent", "waitingChild"])
        // Each one says what it's doing, so the user can choose.
        let activities = SessionRest.activities(sessions, sending: ["sending"], now: now)
        #expect(activities == [
            "idle": .idle, "failed": .idle, "working": .working, "queued": .queued(2), "sending": .sending,
            "terminal": .atTerminal, "background": .backgroundWork, "parent": .subSessionWorking, "child": .working,
            "asking": .waitingForYou, "waitingParent": .subSessionWorking, "waitingChild": .waitingForYou,
        ])
    }

    @Test func puttingSessionsToRestStopsThemAndShowsThemResting() async throws {
        let relay = RestRelay(ids: ["s1", "s2"])
        let store = try relay.store()
        await store.putToRest(["s1", "s2"])
        #expect(relay.stopped == ["s1", "s2"])
        for id in ["s1", "s2"] {
            #expect(store.sessions[id]?.active == false)
            #expect(store.sessions[id]?.isResting == true)
        }
        #expect(store.lastError == nil)
        #expect(store.restingProgress == nil)
    }

    @Test func confirmingPutsToRestExactlyTheChosenSessionsThatAreStillRunning() async throws {
        let relay = RestRelay(ids: ["s1", "s2", "s3"])
        let store = try relay.store()
        #expect(Set(store.restCandidates.all) == ["s1", "s2", "s3"])
        // s2 is unchecked; s3 stopped on its own while the list was up.
        store.sessions["s3"]?.active = false
        await store.confirmRest(["s1", "s3"])
        #expect(relay.stopped == ["s1"])
        #expect(store.sessions["s1"]?.isResting == true)
        #expect(store.sessions["s2"]?.active == true)
        #expect(relay.restWrites == ["s1"])
    }

    @Test func aBusySessionTheUserKeptCheckedIsPutToRest() async throws {
        let relay = RestRelay(ids: ["s1"])
        let store = try relay.store()
        store.sessions["s1"]?.latestTurnStatus = "in_progress"
        store.sessions["s1"]?.latestTurnStatusObservedAt = .now
        #expect(store.restActivities["s1"] == .working)
        await store.confirmRest(["s1"])
        #expect(relay.stopped == ["s1"])
        #expect(store.sessions["s1"]?.isResting == true)
    }

    @Test func aSessionThatCannotBeStoppedIsNotMarkedRestingAndIsReportedOnce() async throws {
        let relay = RestRelay(ids: ["s1", "s2"], refusing: ["s2"])
        let store = try relay.store()
        await store.putToRest(["s1", "s2"])
        #expect(store.sessions["s1"]?.isResting == true)
        #expect(store.sessions["s2"]?.active == true)
        #expect(store.sessions["s2"]?.isResting == false)
        #expect(relay.restWrites == ["s1"])
        let message = try #require(store.lastError)
        #expect(message.contains("Session s2"))
    }
}

/// The relay for sessions on one computer whose daemon stops them (`stop-session`) and which
/// accepts metadata writes (`update-metadata`).
private final class RestRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let ids: [String]
    private let refusing: Set<String>
    private var active: [String: Bool] = [:]
    private var metadata: [String: String] = [:]
    private var versions: [String: Int] = [:]
    private var stops: [String] = []
    private var rests: [String] = []

    init(ids: [String], refusing: Set<String> = []) {
        self.ids = ids
        self.refusing = refusing
        for id in ids {
            active[id] = true
            metadata[id] = #"{"machineId":"m1","path":"/work","flavor":"claude","summary":{"text":"Session \#(id)","updatedAt":1},"lifecycleStateSince":1000}"#
            versions[id] = 1
        }
    }

    var stopped: [String] { lock.withLock { stops.sorted() } }
    var restWrites: [String] { lock.withLock { rests.sorted() } }

    static func session(_ id: String, now: Date, active: Bool = true, thinking: Bool = false, turn: String = "completed",
                        pendingCount: Int = 0, archived: Bool = false, shared: Bool = false, metadata: String = "{}",
                        agentState: String? = nil, extra: [String: JSONValue] = [:]) throws -> Session {
        let ms = JSONValue.number((now.timeIntervalSince1970 * 1000).rounded(.down))
        var row: [String: JSONValue] = [
            "id": .string(id), "seq": 1, "encryptionMode": "plain", "metadata": .string(metadata),
            "active": .bool(active), "activeAt": ms, "thinking": .bool(thinking), "thinkingAt": ms,
            "latestTurnStatus": .string(turn), "latestTurnStatusObservedAt": ms, "pendingCount": .number(Double(pendingCount)),
        ]
        if archived { row["archivedAt"] = ms }
        if shared { row["share"] = ["accessLevel": "view"] }
        if let agentState { row["agentState"] = .string(agentState) }
        row.merge(extra) { $1 }
        return try Session(row: .object(row), keys: nil)
    }

    @MainActor func store() throws -> HappierStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RestURLProtocol.self]
        RestURLProtocol.relay = self
        let api = HappierAPI(server: URL(string: "https://relay.invalid")!, token: "t", session: URLSession(configuration: configuration))
        let store = HappierStore(server: URL(string: "https://relay.invalid")!)
        store.installForTesting(api: api, keys: try AccountKeys(masterSecret: Data(0..<32)),
                                snapshotDirectory: FileManager.default.temporaryDirectory.appending(path: "rest-\(UUID().uuidString)")) { [self] event, payload in
            socketAck(event, payload)
        }
        for id in ids { store.sessions[id] = try Session(row: row(id), keys: nil) }
        return store
    }

    private func row(_ id: String) -> JSONValue {
        lock.withLock {
            let ms = JSONValue.number((Date.now.timeIntervalSince1970 * 1000).rounded(.down))
            let isActive = active[id] ?? false
            return ["id": .string(id), "seq": 3, "encryptionMode": "plain", "metadata": .string(metadata[id] ?? "{}"),
                    "metadataVersion": .number(Double(versions[id] ?? 1)), "active": .bool(isActive), "activeAt": ms,
                    "thinking": false, "latestTurnStatus": "completed", "latestTurnStatusObservedAt": ms]
        }
    }

    private func socketAck(_ event: String, _ payload: JSONValue) -> [JSONValue] {
        if event == "update-metadata", let id = payload["sid"]?.stringValue, let written = payload["metadata"]?.stringValue {
            return lock.withLock {
                let version = (versions[id] ?? 1) + 1
                versions[id] = version
                metadata[id] = written
                if written.contains("sessionRestV1") { rests.append(id) }
                return [["result": "success", "version": .number(Double(version)), "metadata": .string(written)]]
            }
        }
        let method = payload["method"]?.stringValue ?? ""
        if method == "m1:stop-session", let id = payload["params"]?["sessionId"]?.stringValue {
            return lock.withLock {
                stops.append(id)
                if refusing.contains(id) { return [["ok": true, "result": ["status": "incomplete", "reason": "stop_timeout"]]] }
                active[id] = false
                return [["ok": true, "result": ["status": "stopped"]]]
            }
        }
        return [["ok": false, "error": .string("unexpected \(event) \(method)")]]
    }

    func respond(_ request: URLRequest) -> (Int, JSONValue) {
        let path = request.url?.path ?? ""
        if request.httpMethod == "GET", path == "/v1/machines/m1" {
            let plain = Data(#"{"t":"plain"}"#.utf8).base64EncodedString()
            return (200, ["machine": ["id": "m1", "active": true, "dataEncryptionKey": .string(plain)]])
        }
        if request.httpMethod == "GET", path.hasPrefix("/v2/sessions/") {
            return (200, ["session": row(String(path.dropFirst("/v2/sessions/".count)))])
        }
        return (404, ["error": "not found"])
    }
}

private final class RestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var relay: RestRelay?

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

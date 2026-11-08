import Foundation
import Observation
import Testing
@testable import HappierKit

/// `HappierStore` flows with the network simulated at its boundaries: HTTP to the relay through a
/// `URLProtocol`, the socket's acknowledged emits through a closure. Everything above stays real.
@MainActor @Suite(.serialized) struct StoreFlowTests {
    // MARK: startTaskNow

    @Test func startingATaskLinksAndNamesTheSessionBeforeOpeningIt() async throws {
        let relay = Relay()
        let store = relay.store()
        await relay.loadTaskAndAgent(into: store)
        observeOpenRequest(store, relay.log)

        let outcome = await store.startTaskNow(id: "t1", machineId: "m1", directory: "/tmp/radar")

        #expect(outcome == .created(sessionId: "s-new"))
        #expect(store.openRequest == "s-new")
        #expect(relay.log.values == ["spawn", "sessions", "send", "task", "title", "open"])
        let task = try #require(relay.writtenTask)
        #expect(task.status == .inProgress)
        #expect(task.threads.contains("s-new"))
        #expect(relay.writtenTitle == "Publicar build")

        // The caller opens it itself (after closing the task's screen).
        let callerOpens = Relay()
        let other = callerOpens.store()
        await callerOpens.loadTaskAndAgent(into: other)
        observeOpenRequest(other, callerOpens.log)
        #expect(await other.startTaskNow(id: "t1", machineId: "m1", directory: "/tmp/radar", opensSession: false) == .created(sessionId: "s-new"))
        #expect(other.openRequest == nil)
        #expect(callerOpens.log.values == ["spawn", "sessions", "send", "task", "title"])
    }

    // MARK: Light message updates

    @Test func anEditToAClosedSessionKeepsItsTranscriptAndIsReadWhenOpened() async throws {
        let relay = Relay()
        let store = relay.store()
        relay.sessionRows = [try relay.sessionRow(id: "s1", seq: 2)]
        await store.refreshSessions()
        store.open("s1")
        try await until { store.transcripts["s1"]?.isLoaded == true && !store.loadingTranscripts.contains("s1") }
        #expect(userTexts(store, "s1") == ["hola", "adios"])
        store.close("s1")

        // Edited elsewhere; the lean relay only says so for a session not open here.
        relay.messageTexts["m1"] = "hola editado"
        await store.handleUpdate(["t": "message-updated", "sid": "s1", "message": ["id": "m1", "seq": 1, "contentOmitted": true]])
        #expect(userTexts(store, "s1") == ["hola", "adios"])

        relay.log.clear()
        store.open("s1")
        // Shown from the cache at once, not reloaded from empty.
        #expect(userTexts(store, "s1") == ["hola", "adios"])
        try await until { userTexts(store, "s1") == ["hola editado", "adios"] }
        try await until { !store.loadingTranscripts.contains("s1") }
        #expect(relay.log.values.filter { $0.hasPrefix("messages") } == ["messages after=2", "messages latest"])
    }
}

// MARK: - Harness

@MainActor private func observeOpenRequest(_ store: HappierStore, _ log: EventLog) {
    withObservationTracking { _ = store.openRequest } onChange: { log.add("open") }
}

@MainActor private func userTexts(_ store: HappierStore, _ id: String) -> [String] {
    (store.transcripts[id]?.items ?? []).compactMap { if case .userText(let text) = $0 { text.text } else { nil } }
}

@MainActor private func until(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ event: String) { lock.withLock { items.append(event) } }
    func clear() { lock.withLock { items.removeAll() } }
    var values: [String] { lock.withLock { items } }
}

/// The relay and the machine behind it, as the store sees them.
private final class Relay: @unchecked Sendable {
    let keys = try! AccountKeys(masterSecret: Data(0..<32))
    let log = EventLog()
    private let dataKey = Data(repeating: 9, count: 32)
    private let lock = NSLock()
    private var state = (sessionRows: [JSONValue](), messageTexts: ["m1": "hola", "m2": "adios"],
                         writtenTask: AgentTask?.none, writtenTitle: String?.none)

    var sessionRows: [JSONValue] {
        get { lock.withLock { state.sessionRows } }
        set { lock.withLock { state.sessionRows = newValue } }
    }
    var messageTexts: [String: String] {
        get { lock.withLock { state.messageTexts } }
        set { lock.withLock { state.messageTexts = newValue } }
    }
    var writtenTask: AgentTask? { lock.withLock { state.writtenTask } }
    var writtenTitle: String? { lock.withLock { state.writtenTitle } }
    private var machineKey: Data { keys.content.secretKey }
    private var cipher: ContentCipher { .aesGCM(key: dataKey) }

    @MainActor func store() -> HappierStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayURLProtocol.self]
        RelayURLProtocol.relay = self
        let api = HappierAPI(server: URL(string: "https://relay.invalid")!, token: "t", session: URLSession(configuration: configuration))
        let store = HappierStore(server: URL(string: "https://relay.invalid")!)
        let directory = FileManager.default.temporaryDirectory.appending(path: "store-flow-\(UUID().uuidString)")
        store.installForTesting(api: api, keys: keys, snapshotDirectory: directory) { [self] event, payload in
            try socketAck(event, payload)
        }
        return store
    }

    @MainActor func loadTaskAndAgent(into store: HappierStore) async {
        await store.refreshTasks()
        await store.refreshAgentProfiles()
        #expect(store.task(id: "t1") != nil && store.agentProfile(id: "a-mateo") != nil)
    }

    func sessionRow(id: String, seq: Int) throws -> JSONValue {
        let envelope = try HappierCrypto.sealDataKeyEnvelope(dataKey, recipientPublicKey: keys.content.publicKey)
        return [
            "id": .string(id), "seq": .number(Double(seq)), "createdAt": 1, "updatedAt": 2, "active": true, "activeAt": 1,
            "encryptionMode": "e2ee", "dataEncryptionKey": .string(envelope.base64EncodedString()),
            "metadata": .string(try cipher.encryptBase64(["path": "/tmp/radar", "machineId": "m1", "flavor": "codex"])),
            "metadataVersion": 3, "agentState": .null, "agentStateVersion": 1,
        ]
    }

    private func messageRow(id: String, seq: Int) throws -> JSONValue {
        let record: JSONValue = ["role": "user", "content": ["type": "text", "text": .string(messageTexts[id] ?? "")]]
        return ["id": .string(id), "seq": .number(Double(seq)), "createdAt": .number(Double(seq * 1000)),
                "content": ["t": "encrypted", "c": .string(try cipher.encryptBase64(record))]]
    }

    // MARK: Socket

    private func socketAck(_ event: String, _ payload: JSONValue) throws -> [JSONValue] {
        switch event {
        case "rpc-call" where payload["method"]?.stringValue?.hasPrefix("m1:spawn-happy-session") == true:
            log.add("spawn")
            sessionRows = [try sessionRow(id: "s-new", seq: 0)]
            return [["ok": true, "result": ["type": "success", "sessionId": "s-new"]]]
        case "update-metadata":
            log.add("title")
            let ciphertext = payload["metadata"]?.stringValue ?? ""
            lock.withLock { state.writtenTitle = (try? cipher.decryptBase64(ciphertext))?["summary"]?["text"]?.stringValue }
            return [["result": "success", "version": 4, "metadata": .string(ciphertext)]]
        default:
            return [["ok": false, "error": "not simulated"]]
        }
    }

    // MARK: HTTP

    func respond(_ request: URLRequest, body: Data) throws -> (Int, JSONValue) {
        let path = request.url!.path
        let query = Dictionary((URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                               uniquingKeysWith: { $1 })
        switch (request.httpMethod ?? "GET", path) {
        case ("GET", "/v1/kv") where query["prefix"] == AgentTask.kvPrefix:
            let task = TaskScheduledStartTests.task()
            return (200, ["items": [["key": "task/t1", "value": .string(try task.sealed(machineKey: machineKey)), "version": 1]]])
        case ("GET", "/v1/kv") where query["prefix"] == AgentProfile.kvPrefix:
            let agent = AgentProfile(id: "a-mateo", name: "Mateo", providerId: "codex", account: .init(label: ""))
            return (200, ["items": [["key": "agentprofile/a-mateo", "value": .string(try agent.sealed(machineKey: machineKey)), "version": 1]]])
        case ("GET", "/v1/kv"):
            return (200, ["items": []])
        case ("POST", "/v1/kv"):
            log.add("task")
            let mutation = try JSONValue.parse(body)["mutations"]?[0]
            if let value = mutation?["value"]?.stringValue {
                lock.withLock { state.writtenTask = AgentTask.open(value, machineKey: machineKey) }
            }
            return (200, ["success": true, "results": [["key": mutation?["key"] ?? .null, "version": 2]]])
        case ("GET", "/v1/machines/m1"):
            let plain = Data(#"{"t":"plain"}"#.utf8).base64EncodedString()
            return (200, ["machine": ["id": "m1", "active": true, "dataEncryptionKey": .string(plain)]])
        case ("GET", "/v2/cursor"):
            return (200, ["cursor": 1])
        case ("GET", "/v2/sessions"):
            log.add("sessions")
            return (200, ["sessions": .array(sessionRows)])
        case ("POST", "/v2/sessions/s-new/pending"):
            log.add("send")
            return (200, ["ok": true])
        case ("GET", let path) where path.hasSuffix("/pending"):
            return (200, ["pending": []])
        case ("GET", "/v1/sessions/s1/messages"):
            if let after = query["afterSeq"] {
                log.add("messages after=\(after)")
                return (200, ["messages": [], "hasMore": false])
            }
            log.add("messages latest")
            return (200, ["messages": [try messageRow(id: "m1", seq: 1), try messageRow(id: "m2", seq: 2)], "hasMore": false])
        default:
            return (404, ["error": "not simulated"])
        }
    }
}

/// HTTP is the simulated boundary; request building and response parsing stay real.
private final class RelayURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var relay: Relay?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                body.append(contentsOf: bytes.prefix(count))
            }
        }
        let (status, json) = (try? Self.relay?.respond(request, body: body)) ?? (500, ["error": "relay failed"])
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? json.encoded()) ?? Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

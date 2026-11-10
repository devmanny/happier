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

    /// An open conversation redraws only for changes it shows: an update bringing the same agent
    /// state must not rewrite its transcript.
    @Test func theSameAgentStateDoesNotRewriteTheTranscript() async throws {
        let (_, store) = try await openSession()
        let notified = Flag()
        withObservationTracking { _ = store.transcripts["s1"] } onChange: { notified.set() }
        await store.handleUpdate(["t": "update-session", "id": "s1", "agentState": .null])
        #expect(!notified.value, "the same agent state rewrote the transcript")
    }

    /// ...nor a pending queue read again with the same messages.
    @Test func theSamePendingQueueIsNotWrittenAgain() async throws {
        let (_, store) = try await openSession()
        let queueNotified = Flag()
        withObservationTracking { _ = store.pendingQueues["s1"] } onChange: { queueNotified.set() }
        store.refreshPending("s1")
        try await Task.sleep(for: .milliseconds(300))
        #expect(!queueNotified.value, "the same pending queue was written again")
    }

    // MARK: Switching the session's agent

    @Test func switchingTheAgentCarriesTheSessionWriteProofAndNotTheOldAgentsModel() async throws {
        let relay = Relay()
        let store = relay.store()
        // A Codex session running a model of its own.
        relay.sessionRows = [try relay.sessionRow(id: "s1", seq: 2, metadata: [
            "modelOverrideV1": ["v": 1, "updatedAt": 5, "modelId": "gpt-6-astra"],
        ])]
        await store.refreshSessions()
        store.armAgent(.init(agentId: "claude", modelId: "claude-sonnet-5-5"), for: "s1")

        let sent = await store.send("bien", to: "s1")

        // The relay refuses a session write without the proof ("Forbidden").
        #expect(store.lastError == nil)
        #expect(sent)
        let call = try #require(relay.agentTransitionCall)
        #expect(call["authorization"] == ["kind": "session.write", "sessionId": "s1"])
        // Claude's first message doesn't ask for Codex's model.
        #expect(call["params"]?["selection"]?["modelId"] == "claude-sonnet-5-5")
        #expect(call["params"]?["input"]?["meta"]?["model"] == nil)
    }

    @Test func onAnOldDaemonTheSameBareProviderOnlyLeavesTheIdentity() async throws {
        let relay = Relay()
        let store = relay.store()
        // Mateo on Codex; the machine's Happier can't carry an identity in a switch.
        relay.sessionRows = [try relay.sessionRow(id: "s1", seq: 2, metadata: [
            "agentIdentityV1": ["v": 1, "id": "a-mateo", "name": "Mateo"],
        ])]
        await store.refreshSessions()
        store.armAgent(.init(agentId: "codex"), for: "s1")
        #expect(store.armedAgents["s1"] != nil)

        #expect(await store.send("sigue", to: "s1"))

        // No switch (it would be refused as the same agent): the identity leaves the metadata and
        // the message goes as any other, without an error.
        #expect(!relay.log.values.contains("transition"))
        #expect(relay.writtenMetadata?["agentIdentityV1"] == nil && relay.writtenMetadata != nil)
        #expect(relay.log.values.contains("send"))
        #expect(store.lastError == nil)
        #expect(store.armedAgents["s1"] == nil)
    }

    @Test func switchingToABareProviderLeavesTheAgentIdentityBehind() async throws {
        let relay = Relay()
        let store = relay.store()
        // A session working as Mateo (Codex).
        relay.sessionRows = [try relay.sessionRow(id: "s1", seq: 2, metadata: [
            "agentIdentityV1": ["v": 1, "id": "a-mateo", "name": "Mateo"],
        ])]
        await store.refreshSessions()
        store.armAgent(.init(agentId: "claude", modelId: "claude-opus-5-5"), for: "s1")

        #expect(await store.send("bien", to: "s1"))

        // The identity is gone from the metadata before the switch, so Claude isn't named Mateo.
        #expect(relay.log.values.firstIndex(of: "metadata") ?? .max < relay.log.values.firstIndex(of: "transition") ?? -1)
        let written = try #require(relay.writtenMetadata)
        #expect(written["agentIdentityV1"] == nil && written["flavor"] == "codex")
        // A daemon that can't take an identity in the switch gets the shape it knows.
        let selection = try #require(relay.agentTransitionCall?["params"]?["selection"])
        #expect(selection["agentIdentityV1"] == nil && selection["environmentVariables"] == nil)
    }

    // MARK: Switching to an agent profile

    private static let ludo = AgentProfile(id: "a-ludo", name: "Ludo", emoji: "🎙️", providerId: "claude", modelId: "claude-opus-5-5",
                                           effort: "high", account: .init(label: "Ludo", configDir: "~/.claude-ludo"))
    private static let mateo = AgentProfile(id: "a-mateo", name: "Mateo", providerId: "codex", account: .init(label: ""))

    @Test func pickingAnAgentOnADaemonThatTakesIdentitiesSwitchesTheWholeIdentity() async throws {
        let relay = Relay()
        relay.supportsAgentIdentity = true
        let store = relay.store()
        relay.sessionRows = [try relay.sessionRow(id: "s1", seq: 2)]
        await store.refreshSessions()
        store.armAgent(.init(profile: Self.ludo), for: "s1")

        #expect(await store.send("hola", to: "s1"))

        let selection = try #require(relay.agentTransitionCall?["params"]?["selection"])
        #expect(selection["agentId"] == "claude" && selection["modelId"] == "claude-opus-5-5")
        #expect(selection["sessionConfigOptionOverrides"]?["overrides"]?["reasoning_effort"]?["value"] == "high")
        #expect(selection["agentIdentityV1"] == Self.ludo.identityJSON)
        #expect(selection["environmentVariables"] == ["CLAUDE_CONFIG_DIR": "~/.claude-ludo"])
        #expect(relay.writtenMetadata == nil)
    }

    @Test func pickingABareProviderOnADaemonThatTakesIdentitiesClearsItInTheSwitch() async throws {
        let relay = Relay()
        relay.supportsAgentIdentity = true
        let store = relay.store()
        relay.sessionRows = [try relay.sessionRow(id: "s1", seq: 2, metadata: [
            "agentIdentityV1": ["v": 1, "id": "a-mateo", "name": "Mateo"],
        ])]
        await store.refreshSessions()
        store.armAgent(.init(agentId: "claude"), for: "s1")

        #expect(await store.send("bien", to: "s1"))

        let selection = try #require(relay.agentTransitionCall?["params"]?["selection"])
        #expect(selection["agentIdentityV1"] == .null)
        #expect(selection["environmentVariables"] == nil)
        // The daemon clears it as part of the switch: no separate metadata write first.
        #expect(relay.writtenMetadata == nil && !relay.log.values.contains("metadata"))
    }

    @Test func pickingAnAgentOnAnOlderDaemonIsRefusedBeforeAnythingChanges() async throws {
        let relay = Relay()
        let store = relay.store()
        relay.sessionRows = [try relay.sessionRow(id: "s1", seq: 2, metadata: [
            "agentIdentityV1": ["v": 1, "id": "a-mateo", "name": "Mateo"],
        ])]
        await store.refreshSessions()
        store.armAgent(.init(profile: Self.ludo), for: "s1")

        #expect(await store.send("hola", to: "s1") == false)

        #expect(store.lastError != nil)
        #expect(relay.agentTransitionCall == nil && relay.writtenMetadata == nil)
        #expect(store.armedAgents["s1"]?.profile == Self.ludo)
        #expect(store.transcripts["s1"]?.isEmpty ?? true)
    }

    @Test func pickingTheSessionsOwnAgentAgainCancelsTheSwitch() async throws {
        let relay = Relay()
        let store = relay.store()
        relay.sessionRows = [
            try relay.sessionRow(id: "s1", seq: 2, metadata: ["agentIdentityV1": ["v": 1, "id": "a-mateo", "name": "Mateo"]]),
            try relay.sessionRow(id: "s2", seq: 2),
        ]
        await store.refreshSessions()

        // Working as Mateo (Codex): Mateo again is no switch; bare Codex, or Mateo at another effort, is one.
        store.armAgent(.init(profile: Self.mateo), for: "s1")
        #expect(store.armedAgents["s1"] == nil)
        store.armAgent(.init(agentId: "codex"), for: "s1")
        #expect(store.armedAgents["s1"] == .init(agentId: "codex"))
        store.armAgent(.init(profile: Self.mateo), for: "s1")
        #expect(store.armedAgents["s1"] == nil)
        store.armAgent(.init(profile: Self.mateo, modelId: nil, effort: "high"), for: "s1")
        #expect(store.armedAgents["s1"]?.effort == "high")

        // A bare Codex session: Mateo is another agent on the same provider; bare Codex cancels.
        store.armAgent(.init(profile: Self.mateo), for: "s2")
        #expect(store.armedAgents["s2"]?.profile == Self.mateo)
        store.armAgent(.init(agentId: "codex"), for: "s2")
        #expect(store.armedAgents["s2"] == nil)
    }

    @Test func afterSwitchingTheAgentTheUsageShownIsTheNewProvidersNotTheOldOnes() async throws {
        let relay = Relay()
        let store = relay.store()
        // The session points at both providers' readings; Codex's is the newer one.
        let refs: [String: JSONValue] = ["providerAccountUsageRefsV1": ["recordIds": ["r-claude", "r-codex"]]]
        relay.sessionRows = [try relay.sessionRow(id: "s1", seq: 2, metadata: refs)]
        await store.refreshSessions()
        await store.refreshProviderUsage("s1")
        #expect(store.usage(for: "s1")?.providerId == "codex")

        // Now it's Claude's session: Codex's reading, still cached, isn't shown for it.
        relay.sessionRows = [try relay.sessionRow(id: "s1", seq: 3, metadata: refs.merging(["flavor": "claude"]) { $1 }, metadataVersion: 4)]
        await store.refreshSessions()
        #expect(store.usage(for: "s1")?.providerId != "codex")
        await store.refreshProviderUsage("s1")
        #expect(store.usage(for: "s1")?.providerId == "claude")
    }

    @Test func aReadingTheSessionNoLongerPointsAtIsNotItsUsage() async throws {
        let relay = Relay()
        let store = relay.store()
        // The session ran on another account; that account's reading is cached here.
        let claude: [String: JSONValue] = ["flavor": "claude"]
        relay.sessionRows = [try relay.sessionRow(id: "s1", seq: 2, metadata: claude.merging(["providerAccountUsageRefsV1": ["recordIds": ["r-claude"]]]) { $1 })]
        await store.refreshSessions()
        await store.refreshProviderUsage("s1")
        #expect(store.usage(for: "s1")?.providerId == "claude")

        // Its reading is dropped (it now runs on its own account): the old account's numbers go too.
        relay.sessionRows = [try relay.sessionRow(id: "s1", seq: 3, metadata: claude.merging(["providerAccountUsageRefsV1": ["recordIds": []]]) { $1 }, metadataVersion: 4)]
        await store.refreshSessions()
        #expect(store.usage(for: "s1") == nil)
    }

    // MARK: This device cut off from the relay

    @Test func cutOffFromTheRelayWhatTheRelayReportedIsJudgedWhenTheLinkWasLost() throws {
        let store = Relay().store()
        let lost = Date(timeIntervalSince1970: 1_000_000)
        store.relayLinkChanged(to: .online, at: lost.addingTimeInterval(-60))
        store.relayLinkChanged(to: .offline, at: lost)
        let later = lost.addingTimeInterval(600)
        #expect(!store.reachesRelay)
        #expect(store.presenceDate(later) == lost)
        // A machine last heard from just before isn't "offline" ten minutes into the outage.
        let plain = Data(#"{"t":"plain"}"#.utf8).base64EncodedString()
        let machine = try Machine(row: ["id": "m1", "active": true, "activeAt": .number((lost.timeIntervalSince1970 - 30) * 1000),
                                        "dataEncryptionKey": .string(plain)], keys: nil)
        #expect(machine.isOnline(at: store.presenceDate(later)))
        // Retrying keeps the time the link was lost; back online, time runs again.
        store.relayLinkChanged(to: .offline, at: lost.addingTimeInterval(30))
        #expect(store.presenceDate(later) == lost)
        store.relayLinkChanged(to: .online, at: later)
        #expect(store.reachesRelay && store.presenceDate(later) == later)
    }

    @Test func theOfflineNoticeSaysWhetherThisDeviceHasNoNetworkOrTheServerDoesntAnswer() async throws {
        let path = SimulatedNetworkPath()
        let store = Relay().store(networkPath: path)
        store.relayLinkChanged(to: .online)
        #expect(store.offlineNotice == nil)
        store.relayLinkChanged(to: .offline)
        #expect(store.offlineNotice == .serverNotResponding)
        path.send(satisfied: false)
        try await until { store.offlineNotice == .noNetwork }
        // A reconnect attempt in progress after the loss still shows it; connecting clears it.
        path.send(satisfied: true)
        try await until { store.offlineNotice == .serverNotResponding }
        store.relayLinkChanged(to: .online)
        #expect(store.offlineNotice == nil)
    }

    @Test func losingTheNetworkPathLosesTheRelayLinkAtOnce() async throws {
        let path = SimulatedNetworkPath()
        let store = Relay().store(networkPath: path)
        store.relayLinkChanged(to: .online)
        // No network path: the relay can't be reached, without waiting for the socket to time out.
        path.send(satisfied: false)
        try await until { !store.reachesRelay }
        #expect(store.connection == .offline && store.linkLostAt != nil)
        #expect(store.offlineNotice == .noNetwork)
    }

    @Test func automaticMachineRefreshesDontRaiseAlerts() async {
        // The relay doesn't answer `/v1/machines` here: a failure.
        let store = Relay().store()
        await store.refreshMachines()
        #expect(store.lastError == nil)
        await store.refreshMachines(reportErrors: true)
        #expect(store.lastError != nil)
    }

    @MainActor private func openSession() async throws -> (Relay, HappierStore) {
        let relay = Relay()
        let store = relay.store()
        relay.sessionRows = [try relay.sessionRow(id: "s1", seq: 2)]
        await store.refreshSessions()
        store.open("s1")
        try await until { store.transcripts["s1"]?.isLoaded == true && !store.loadingTranscripts.contains("s1") }
        try await until { store.pendingQueues["s1"] != nil && !store.loadingTranscripts.contains("s1") }
        try await Task.sleep(for: .milliseconds(200))
        return (relay, store)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
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

/// The system's network path monitor, driven by the test.
final class SimulatedNetworkPath: NetworkPathMonitor, @unchecked Sendable {
    private let lock = NSLock()
    private var onChange: (@Sendable (Bool) -> Void)?
    func start(_ onChange: @escaping @Sendable (Bool) -> Void) { lock.withLock { self.onChange = onChange } }
    func cancel() { lock.withLock { onChange = nil } }
    func send(satisfied: Bool) { lock.withLock { onChange }?(satisfied) }
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
                         writtenTask: AgentTask?.none, writtenTitle: String?.none, agentTransitionCall: JSONValue?.none,
                         writtenMetadata: JSONValue?.none, supportsAgentIdentity: false)

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
    var agentTransitionCall: JSONValue? { lock.withLock { state.agentTransitionCall } }
    var writtenMetadata: JSONValue? { lock.withLock { state.writtenMetadata } }
    /// Whether the machine's daemon takes an agent identity in a switch; false is an older daemon.
    var supportsAgentIdentity: Bool {
        get { lock.withLock { state.supportsAgentIdentity } }
        set { lock.withLock { state.supportsAgentIdentity = newValue } }
    }
    private var machineKey: Data { keys.content.secretKey }
    private var cipher: ContentCipher { .aesGCM(key: dataKey) }

    @MainActor func store(networkPath: NetworkPathMonitor? = nil) -> HappierStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayURLProtocol.self]
        RelayURLProtocol.relay = self
        let api = HappierAPI(server: URL(string: "https://relay.invalid")!, token: "t", session: URLSession(configuration: configuration))
        let store = HappierStore(server: URL(string: "https://relay.invalid")!)
        let directory = FileManager.default.temporaryDirectory.appending(path: "store-flow-\(UUID().uuidString)")
        store.installForTesting(api: api, keys: keys, snapshotDirectory: directory, networkPath: networkPath) { [self] event, payload in
            try socketAck(event, payload)
        }
        return store
    }

    @MainActor func loadTaskAndAgent(into store: HappierStore) async {
        await store.refreshTasks()
        await store.refreshAgentProfiles()
        #expect(store.task(id: "t1") != nil && store.agentProfile(id: "a-mateo") != nil)
    }

    func sessionRow(id: String, seq: Int, metadata extra: [String: JSONValue] = [:], metadataVersion: Int = 3) throws -> JSONValue {
        let envelope = try HappierCrypto.sealDataKeyEnvelope(dataKey, recipientPublicKey: keys.content.publicKey)
        let metadata: [String: JSONValue] = ["path": "/tmp/radar", "machineId": "m1", "flavor": "codex"]
        return [
            "id": .string(id), "seq": .number(Double(seq)), "createdAt": 1, "updatedAt": 2, "active": true, "activeAt": 1,
            "encryptionMode": "e2ee", "dataEncryptionKey": .string(envelope.base64EncodedString()),
            "metadata": .string(try cipher.encryptBase64(.object(metadata.merging(extra) { $1 }))),
            "metadataVersion": .number(Double(metadataVersion)), "agentState": .null, "agentStateVersion": 1,
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
        case "rpc-call" where payload["method"]?.stringValue == "m1:capabilities.detect":
            // `capabilities.ts`: an older daemon reports only the permission-intent support.
            var data: [String: JSONValue] = ["supportsInputPermissionIntent": true]
            if supportsAgentIdentity { data["supportsAgentIdentity"] = true }
            return [["ok": true, "result": ["protocolVersion": 1, "results": [
                "tool.sessionAgentTransition": ["ok": true, "checkedAt": 1, "data": .object(data)],
            ]]]]
        case "rpc-call" where payload["method"]?.stringValue == "m1:session.agentTransition":
            // The relay's check (`rpcHandler.ts`): a session write without its proof is refused.
            log.add("transition")
            lock.withLock { state.agentTransitionCall = payload }
            guard payload["authorization"]?["kind"] == "session.write" else { return [["ok": false, "error": "Forbidden", "errorCode": "RPC_FORBIDDEN"]] }
            return [["ok": true, "result": ["type": "accepted"]]]
        case "update-metadata":
            let ciphertext = payload["metadata"]?.stringValue ?? ""
            let written = try? cipher.decryptBase64(ciphertext)
            log.add(written?["summary"] != nil ? "title" : "metadata")
            lock.withLock {
                state.writtenTitle = written?["summary"]?["text"]?.stringValue
                state.writtenMetadata = written
            }
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
        case ("GET", let path) where path.hasPrefix("/v3/connect/provider-account-usage/"):
            let provider = path.hasSuffix("r-claude") ? "claude" : "codex"
            let snapshot: JSONValue = ["v": 1, "providerId": .string(provider), "fetchedAtMs": provider == "codex" ? 2_000 : 1_000,
                                       "staleAfterMs": 300_000, "meters": [["meterId": "session", "utilizationPct": 40]]]
            return (200, ["content": ["t": "plain", "v": snapshot]])
        case ("GET", "/v2/changes"):
            // The cursor is gone: the list is read again in full.
            return (410, ["error": "cursor-expired"])
        case ("GET", "/v2/cursor"):
            return (200, ["cursor": 1])
        case ("GET", "/v2/sessions"):
            log.add("sessions")
            return (200, ["sessions": .array(sessionRows)])
        case ("POST", let path) where path.hasPrefix("/v2/sessions/") && path.hasSuffix("/pending"):
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

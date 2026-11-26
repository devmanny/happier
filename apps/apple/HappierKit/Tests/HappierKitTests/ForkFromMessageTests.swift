import Foundation
import Testing
@testable import HappierKit

/// Going back to a message, as in a Claude chat: the session forks on its machine
/// (`session.fork`), the branch opens with the message back in the composer to edit, and it shows
/// the conversation up to that message.
@MainActor @Suite(.serialized)
struct ForkFromMessageTests {
    @Test func editingAMessageForksOnceAndOpensTheBranchWithItsText() async throws {
        let relay = ForkRelay()
        let store = try relay.store()
        // A second tap while the first is still on its way must not make a second branch.
        async let first: Void = store.fork("p", upToSeq: 3, restoring: "Arregla el login")
        async let second: Void = store.fork("p", upToSeq: 3, restoring: "Arregla el login")
        _ = await (first, second)

        #expect(relay.forkRequests.count == 1)
        let request = try #require(relay.forkRequests.first)
        #expect(request["parentSessionId"]?.stringValue == "p")
        #expect(request["forkPoint"]?["upToSeqInclusive"]?.intValue == 3)
        // The daemon coalesces retries of one tap on this key.
        #expect(request["requestId"]?.stringValue?.isEmpty == false)
        #expect(store.openRequest == "c")
        #expect(store.draftSeeds["c"] == "Arregla el login")
        #expect(store.forkingSessions.isEmpty)
        #expect(store.lastError == nil)
    }

    @Test func aBranchWhoseAnswerWasLostIsFoundInsteadOfForkedAgain() async throws {
        // The daemon was still creating it when the answer came back as a timeout.
        let relay = ForkRelay(answer: { _ in ["ok": false, "errorCode": "SESSION_WEBHOOK_TIMEOUT", "errorMessage": "Timed out"] })
        let store = try relay.store()
        await store.fork("p", upToSeq: 3, restoring: "Arregla el login")

        #expect(relay.forkRequests.count == 1)
        #expect(store.openRequest == "c")
        #expect(store.draftSeeds["c"] == "Arregla el login")
        #expect(store.lastError == nil)
    }

    @Test func tappingAgainAfterALostAnswerAsksForTheSameBranch() async throws {
        // Timed out, and the branch doesn't show up in time: it may still be on its way.
        let relay = ForkRelay(listsChild: false, answer: { _ in ["ok": false, "errorCode": "UNEXPECTED", "errorMessage": "Lost"] })
        let store = try relay.store()
        store.forkLookupDelay = .milliseconds(1)
        await store.fork("p", upToSeq: 3, restoring: "Arregla el login")
        #expect(store.lastError != nil)
        await store.fork("p", upToSeq: 3, restoring: "Arregla el login")
        // The daemon folds the second tap into the first fork instead of making another.
        #expect(relay.forkRequests.count == 2)
        let keys = relay.forkRequests.compactMap { $0["requestId"]?.stringValue }
        #expect(keys.count == 2 && keys[0] == keys[1])
    }

    @Test func aBorrowedMessageOfAConversationNoLongerListedCanStillBeEdited() async throws {
        // `p` was archived after the branch was made: the list no longer has it.
        let relay = ForkRelay(listsParent: false)
        let store = try relay.store()
        store.sessions["p"] = nil
        store.sessions["c"] = try Session(row: relay.child(requestId: nil), keys: nil)
        store.open("c")
        for _ in 0..<300 where store.conversationItems("c").isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let borrowed = try #require(store.conversationItems("c").first)
        #expect(store.forkContextSession(ofItem: borrowed.id, in: "c") == "p")

        await store.fork("p", upToSeq: 1, restoring: nil)
        #expect(relay.forkRequests.count == 1)
    }

    @Test func aBranchWhoseConversationWasDeletedStopsLookingForIt() async throws {
        let relay = ForkRelay(listsParent: false, parentGone: true)
        let store = try relay.store()
        store.sessions["p"] = nil
        store.sessions["c"] = try Session(row: relay.child(requestId: nil), keys: nil)
        store.open("c")
        for _ in 0..<300 where store.hasOlderForkContext("c") { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!store.hasOlderForkContext("c"))
        #expect(store.conversationItems("c").isEmpty)
    }

    @Test func aDaemonTooOldForTheKeyIsAskedWithoutIt() async throws {
        let relay = ForkRelay(daemonVersion: "0.2.10-dev.40")
        let store = try relay.store()
        await store.fork("p", upToSeq: 3, restoring: nil)
        #expect(relay.forkRequests.first?["requestId"] == nil)
        #expect(store.openRequest == "c")
    }

    @Test func theBranchShowsTheConversationBeforeTheMessage() async throws {
        let relay = ForkRelay()
        let store = try relay.store()
        await store.fork("p", upToSeq: 3, restoring: "Arregla el login")
        store.open("c")
        for _ in 0..<300 where store.conversationItems("c").count < 3 { try await Task.sleep(for: .milliseconds(10)) }

        let items = store.conversationItems("c")
        let texts = items.compactMap { item -> String? in
            switch item {
            case .userText(let user): user.text
            case .agentText(let agent): agent.text
            default: nil
            }
        }
        // Up to the message (the daemon cuts before an edited user message), never past it.
        #expect(texts == ["Hola", "Hola, ¿qué hacemos?"])
        // Between the borrowed conversation and the branch's own, a line says where it branched.
        guard case .event(let divider) = items.last else { Issue.record("no fork divider"); return }
        #expect(divider.kind == "fork")
        // Its own line, not a step folded into the reply before it.
        guard case .item(.event(let shown)) = ChatRow.rows(from: items, working: false).last else { Issue.record("divider folded"); return }
        #expect(shown.kind == "fork")
        // Borrowed rows act on the conversation they come from.
        let borrowed = try #require(items.first)
        #expect(store.forkContextSession(ofItem: borrowed.id, in: "c") == "p")
        #expect(store.forkContextSession(ofItem: divider.id, in: "c") == nil)
    }
}

/// One Claude session `p` on machine `m1` with four messages; forking it creates `c`.
private final class ForkRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let answer: @Sendable (JSONValue) -> JSONValue
    private let daemonVersion: String
    private let listsChild: Bool
    private let listsParent: Bool
    private let parentGone: Bool
    private var requests: [JSONValue] = []
    private var made: JSONValue?

    init(daemonVersion: String = "0.2.19-dev.3", listsChild: Bool = true, listsParent: Bool = true, parentGone: Bool = false,
         answer: @escaping @Sendable (JSONValue) -> JSONValue = { _ in ["ok": true, "childSessionId": "c"] }) {
        self.daemonVersion = daemonVersion
        self.listsChild = listsChild
        self.listsParent = listsParent
        self.parentGone = parentGone
        self.answer = answer
    }

    var forkRequests: [JSONValue] { lock.withLock { requests } }

    @MainActor func store() throws -> HappierStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ForkURLProtocol.self]
        ForkURLProtocol.relay = self
        let api = HappierAPI(server: URL(string: "https://relay.invalid")!, token: "t", session: URLSession(configuration: configuration))
        let store = HappierStore(server: URL(string: "https://relay.invalid")!)
        store.installForTesting(api: api, keys: try AccountKeys(masterSecret: Data(0..<32)),
                                snapshotDirectory: FileManager.default.temporaryDirectory.appending(path: "fork-\(UUID().uuidString)")) { [self] _, payload in
            try await socketAck(payload)
        }
        store.sessions["p"] = try Session(row: parentRow, keys: nil)
        return store
    }

    private let parentRow: JSONValue = [
        "id": "p", "seq": 4, "encryptionMode": "plain", "active": true,
        "metadata": .string(#"{"machineId":"m1","path":"/work","flavor":"claude"}"#),
    ]

    func child(requestId: String?) -> JSONValue {
        var fork: [String: JSONValue] = ["v": 1, "parentSessionId": "p", "parentCutoffSeqInclusive": 2,
                                         "createdAtMs": 1_790_000_000_000, "strategy": "replay"]
        if let requestId { fork["requestId"] = .string(requestId) }
        let metadata: JSONValue = ["machineId": "m1", "path": "/work", "flavor": "claude", "forkV1": .object(fork)]
        return ["id": "c", "seq": 0, "encryptionMode": "plain", "active": true,
                "metadata": .string(String(decoding: (try? metadata.encoded()) ?? Data(), as: UTF8.self))]
    }

    private func socketAck(_ payload: JSONValue) async throws -> [JSONValue] {
        guard payload["method"]?.stringValue == "m1:session.fork" else { return [["ok": false, "error": "unexpected"]] }
        let params = payload["params"] ?? .null
        let first: Bool = lock.withLock {
            requests.append(params)
            made = child(requestId: params["requestId"]?.stringValue)
            return requests.count == 1
        }
        // Slow enough for a second tap to arrive while the first is in flight.
        if first { try await Task.sleep(for: .milliseconds(50)) }
        return [["ok": true, "result": answer(params)]]
    }

    private func message(_ seq: Int, _ role: String, _ text: String) -> JSONValue {
        let content: JSONValue = role == "user"
            ? ["role": "user", "content": ["type": "text", "text": .string(text)]]
            : ["role": "agent", "content": ["type": "codex", "data": ["type": "message", "message": .string(text)]]]
        return ["id": .string("p-\(seq)"), "seq": .number(Double(seq)), "createdAt": .number(Double(1_790_000_000_000 + seq * 1000)),
                "content": ["t": "plain", "v": content]]
    }

    func respond(_ request: URLRequest) -> (Int, JSONValue) {
        let url = request.url
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url!, resolvingAgainstBaseURL: false)?
            .queryItems?.map { ($0.name, $0.value ?? "") } ?? [])
        switch (request.httpMethod ?? "GET", url?.path ?? "") {
        case ("GET", "/v1/machines/m1"):
            let plain = Data(#"{"t":"plain"}"#.utf8).base64EncodedString()
            // A plain machine's documents: base64 of `{t:"plain", v}`.
            let daemonState = Data(#"{"t":"plain","v":{"startedWithCliVersion":"\#(daemonVersion)"}}"#.utf8).base64EncodedString()
            return (200, ["machine": ["id": "m1", "active": true, "dataEncryptionKey": .string(plain),
                                      "daemonState": .string(daemonState)]])
        case ("GET", "/v2/sessions"):
            let child = listsChild ? lock.withLock { made } : nil
            return (200, ["sessions": .array((listsParent ? [parentRow] : []) + (child.map { [$0] } ?? [])), "hasNext": false])
        case ("GET", "/v2/sessions/c"):
            return (200, ["session": lock.withLock { made } ?? .null])
        case ("GET", "/v2/sessions/p"):
            return parentGone ? (404, ["error": "not found"]) : (200, ["session": parentRow])
        case ("GET", "/v1/sessions/p/messages"):
            let all = [message(1, "user", "Hola"), message(2, "agent", "Hola, ¿qué hacemos?"),
                       message(3, "user", "Arregla el login"), message(4, "agent", "Listo")]
            let before = query["beforeSeq"].flatMap(Int.init) ?? Int.max
            let rows = all.filter { ($0["seq"]?.intValue ?? 0) < before }.reversed()
            return (200, ["messages": .array(Array(rows)), "hasMore": false])
        case ("GET", "/v1/sessions/c/messages"):
            return (200, ["messages": [], "hasMore": false])
        default:
            return (200, [:])
        }
    }
}

private final class ForkURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var relay: ForkRelay?

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

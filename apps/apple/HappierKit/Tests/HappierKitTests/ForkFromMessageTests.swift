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

    @Test func anEditedMessageShowsItsVersionsAndSwitchesBetweenThem() async throws {
        // `c` is an edit of p's message 3 that was sent; `d` was made from it too but never sent.
        let relay = ForkRelay(branches: ["c": .init(messages: [("user", "Arregla el registro"), ("agent", "Listo")]), "d": .init(messages: [])])
        let store = try relay.store()
        func versions(_ seq: Int, in id: String) async throws -> MessageVersions? {
            for _ in 0..<300 where store.versions(ofMessageAt: seq, in: id) == nil { try await Task.sleep(for: .milliseconds(10)) }
            return store.versions(ofMessageAt: seq, in: id)
        }

        let original = try #require(try await versions(3, in: "p"))
        #expect(original.all == [MessageVersion(sessionId: "p", seq: 3), MessageVersion(sessionId: "c", seq: 1)])
        #expect(original.current == 0)
        // The branch's first message is the other side of the same pair.
        let edited = try #require(try await versions(1, in: "c"))
        #expect(edited.all == original.all)
        #expect(edited.current == 1)
        // A message nobody edited has a single version.
        #expect(store.versions(ofMessageAt: 1, in: "p") == nil)

        // Switching opens the other version at that message: where conversations open, or in
        // the window the arrows are in.
        await store.openVersion(edited.all[0])
        #expect(store.messageRequest == MessageRequest(sessionId: "p", seq: 3, lit: false))
        #expect(store.openRequest == "p")
        var shown: String?
        await store.openVersion(original.all[1]) { shown = $0 }
        #expect(shown == "c")
        #expect(store.messageRequest == MessageRequest(sessionId: "c", seq: 1, lit: false))
        #expect(store.openRequest == "p")
    }

    @Test func aBranchWhoseOriginalIsGoneStopsAskingForIt() async throws {
        let relay = ForkRelay(branches: ["c": .init(messages: [("user", "Arregla el registro")])])
        let store = try relay.store()
        store.open("c")
        for _ in 0..<300 where store.conversationItems("c").isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        // Deleted elsewhere after the branch showed it: the list just loses it.
        store.sessions["p"] = nil
        relay.parentGone = true
        // Every redraw of the branch's first message asks for its versions.
        for _ in 0..<30 {
            _ = store.versions(ofMessageAt: 1, in: "c")
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(relay.requests("GET /v2/sessions/p") <= 1)
    }

    @Test func deletingTheOriginalTakesItsArrowsAway() async throws {
        let relay = ForkRelay(branches: ["c": .init(messages: [("user", "Arregla el registro")])])
        let store = try relay.store()
        for _ in 0..<300 where store.versions(ofMessageAt: 1, in: "c") == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.versions(ofMessageAt: 1, in: "c") != nil)
        // Stopped, so it can be deleted.
        store.sessions["p"] = try Session(row: relay.parent(seq: 4, active: false), keys: nil)
        await store.confirmDelete(try #require(store.sessions["p"]))
        #expect(store.versions(ofMessageAt: 1, in: "c") == nil)
        // Nothing left to make another version of: it's edited in the branch.
        #expect(store.editTarget(forMessageAt: 1, in: "c") == MessageVersion(sessionId: "c", seq: 1))
    }

    @Test func aBranchMadeMidReplyStopsAskingOnceItsOriginalMovesOn() async throws {
        // `e` was made from p's latest reply while its agent kept working.
        let relay = ForkRelay(branches: ["e": .init(cutoff: 4, messages: [("user", "Otra cosa")])])
        let store = try relay.store()
        for seq in 4...8 {
            relay.parentRows = seq
            store.sessions["p"] = try Session(row: relay.parent(seq: seq), keys: nil)
            for _ in 0..<5 {
                _ = store.versions(ofMessageAt: 1, in: "e")
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        // Once there's a reply right after where it was made, it isn't a version of anything.
        #expect(store.versions(ofMessageAt: 1, in: "e") == nil)
        #expect(relay.requests("GET /v1/sessions/p/messages afterSeq=4") <= 2)
    }

    @Test func anotherVersionCanBeMadeOfAnArchivedOriginal() async throws {
        let relay = ForkRelay(listsParent: false, branches: ["c": .init(messages: [("user", "Arregla el registro")])])
        let store = try relay.store()
        // Archived: not listed, and nothing borrowed from it yet.
        store.sessions["p"] = nil
        for _ in 0..<300 where store.editTarget(forMessageAt: 1, in: "c") != MessageVersion(sessionId: "p", seq: 3) {
            _ = store.versions(ofMessageAt: 1, in: "c")
            try await Task.sleep(for: .milliseconds(10))
        }
        await store.fork("p", upToSeq: 3, restoring: "Arregla el registro")
        #expect(relay.forkRequests.count == 1)
        #expect(store.lastError == nil)
    }

    @Test func aBranchNotMadeFromYourMessageStillHasVersionsOfItsOwn() async throws {
        // `f` was made from p's latest reply; its first message (after a model change) was then
        // edited into `g`.
        let relay = ForkRelay(branches: [
            "f": .init(cutoff: 4, messages: [("agent", "Modelo cambiado"), ("user", "Hola de nuevo")]),
            "g": .init(parent: "f", cutoff: 1, messages: [("user", "Hola otra vez")]),
        ])
        let store = try relay.store()
        for _ in 0..<300 where store.versions(ofMessageAt: 2, in: "f") == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.versions(ofMessageAt: 2, in: "f")?.all == [MessageVersion(sessionId: "f", seq: 2), MessageVersion(sessionId: "g", seq: 1)])
        #expect(store.versions(ofMessageAt: 2, in: "f")?.current == 0)
    }

    @Test func aLookupThatFailedIsAskedAgainOnItsOwn() async throws {
        let relay = ForkRelay(branches: ["c": .init(messages: [("user", "Arregla el registro")])], failingOnce: ["c"])
        let store = try relay.store()
        store.versionLookupRetry = .milliseconds(50)
        for _ in 0..<300 where store.branchesByAnchor.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        _ = store.versions(ofMessageAt: 3, in: "p")
        for _ in 0..<300 where relay.requests("GET /v1/sessions/c/messages") < 1 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(20))
        // Nothing else changes, so the arrows only ask again if the store tells them to.
        let redrawn = Flag()
        withObservationTracking { _ = store.versions(ofMessageAt: 3, in: "p") } onChange: { redrawn.set() }
        for _ in 0..<300 where !redrawn.value { try await Task.sleep(for: .milliseconds(10)) }
        #expect(redrawn.value)
        for _ in 0..<300 where store.versions(ofMessageAt: 3, in: "p") == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.versions(ofMessageAt: 3, in: "p")?.all.count == 2)
    }

    @Test func editingAVersionAgainMakesAnotherVersionOfTheSameMessage() async throws {
        let relay = ForkRelay(branches: ["c": .init(messages: [("user", "Arregla el registro"), ("agent", "Listo")])])
        let store = try relay.store()
        for _ in 0..<300 where store.editTarget(forMessageAt: 1, in: "c") != MessageVersion(sessionId: "p", seq: 3) {
            _ = store.versions(ofMessageAt: 1, in: "c")
            try await Task.sleep(for: .milliseconds(10))
        }
        // Not a branch of the branch: the message it's a version of is edited again.
        let target = store.editTarget(forMessageAt: 1, in: "c")
        #expect(target == MessageVersion(sessionId: "p", seq: 3))
        await store.fork(target.sessionId, upToSeq: target.seq, restoring: "Arregla el registro")
        #expect(relay.forkRequests.last?["parentSessionId"]?.stringValue == "p")
        #expect(relay.forkRequests.last?["forkPoint"]?["upToSeqInclusive"]?.intValue == 3)
        // A later message of the branch is edited in the branch itself.
        #expect(store.editTarget(forMessageAt: 3, in: "c") == MessageVersion(sessionId: "c", seq: 3))
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

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
}

/// One Claude session `p` on machine `m1` with four messages; forking it creates `c`.
private final class ForkRelay: @unchecked Sendable {
    /// A branch already there: where it was made from, and its own messages.
    struct Branch {
        var parent = "p"
        var cutoff = 2
        var messages: [(String, String)]
    }

    private let lock = NSLock()
    private let answer: @Sendable (JSONValue) -> JSONValue
    private let daemonVersion: String
    private let listsChild: Bool
    private let listsParent: Bool
    private var gone: Bool
    private let branches: [String: Branch]
    private var failing: Set<String>
    private var rows = 4
    private var requests: [JSONValue] = []
    private var made: JSONValue?
    private var log: [String] = []

    init(daemonVersion: String = "0.2.19-dev.3", listsChild: Bool = true, listsParent: Bool = true, parentGone: Bool = false,
         branches: [String: Branch] = [:], failingOnce: Set<String> = [],
         answer: @escaping @Sendable (JSONValue) -> JSONValue = { _ in ["ok": true, "childSessionId": "c"] }) {
        self.daemonVersion = daemonVersion
        self.listsChild = listsChild
        self.listsParent = listsParent
        self.gone = parentGone
        self.branches = branches
        self.failing = failingOnce
        self.answer = answer
    }

    /// p is deleted: the relay answers 404 for it.
    var parentGone: Bool {
        get { lock.withLock { gone } }
        set { lock.withLock { gone = newValue } }
    }
    /// p's messages: the four above, then its agent's replies up to this seq.
    var parentRows: Int {
        get { lock.withLock { rows } }
        set { lock.withLock { rows = newValue } }
    }
    /// Requests seen whose "METHOD path[ afterSeq=n]" starts so.
    func requests(_ prefix: String) -> Int { lock.withLock { log.filter { $0.hasPrefix(prefix) }.count } }

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
        for (id, branch) in branches.sorted(by: { $0.key < $1.key }) {
            store.sessions[id] = try Session(row: child(requestId: nil, id: id, seq: branch.messages.count,
                                                        parent: branch.parent, cutoff: branch.cutoff), keys: nil)
        }
        return store
    }

    private var parentRow: JSONValue { parent(seq: 4) }

    func parent(seq: Int, active: Bool = true) -> JSONValue {
        ["id": "p", "seq": .number(Double(seq)), "encryptionMode": "plain", "active": .bool(active),
         "metadata": .string(#"{"machineId":"m1","path":"/work","flavor":"claude"}"#)]
    }

    func child(requestId: String?, id: String = "c", seq: Int = 0, parent: String = "p", cutoff: Int = 2) -> JSONValue {
        var fork: [String: JSONValue] = ["v": 1, "parentSessionId": .string(parent), "parentCutoffSeqInclusive": .number(Double(cutoff)),
                                         "createdAtMs": 1_790_000_000_000, "strategy": "replay"]
        if let requestId { fork["requestId"] = .string(requestId) }
        let metadata: JSONValue = ["machineId": "m1", "path": "/work", "flavor": "claude", "forkV1": .object(fork)]
        return ["id": .string(id), "seq": .number(Double(seq)), "encryptionMode": "plain", "active": true,
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

    private func message(_ seq: Int, _ role: String, _ text: String, in session: String = "p") -> JSONValue {
        let content: JSONValue = role == "user"
            ? ["role": "user", "content": ["type": "text", "text": .string(text)]]
            : ["role": "agent", "content": ["type": "codex", "data": ["type": "message", "message": .string(text)]]]
        return ["id": .string("\(session)-\(seq)"), "seq": .number(Double(seq)), "createdAt": .number(Double(1_790_000_000_000 + seq * 1000)),
                "content": ["t": "plain", "v": content]]
    }

    func respond(_ request: URLRequest) -> (Int, JSONValue) {
        let url = request.url
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url!, resolvingAgainstBaseURL: false)?
            .queryItems?.map { ($0.name, $0.value ?? "") } ?? [])
        lock.withLock { log.append("\(request.httpMethod ?? "GET") \(url?.path ?? "")" + (query["afterSeq"].map { " afterSeq=\($0)" } ?? "")) }
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
            return parentGone ? (404, ["error": "not found"]) : (200, ["session": parent(seq: parentRows)])
        case ("GET", let path) where path.hasPrefix("/v1/sessions/") && path.hasSuffix("/messages"):
            let id = String(path.split(separator: "/")[2])
            if lock.withLock({ failing.remove(id) }) != nil { return (500, ["error": "unavailable"]) }
            let all = id == "p"
                ? [message(1, "user", "Hola"), message(2, "agent", "Hola, ¿qué hacemos?"),
                   message(3, "user", "Arregla el login"), message(4, "agent", "Listo")]
                    + (4..<max(4, parentRows)).map { message($0 + 1, "agent", "Sigue") }
                : (branches[id]?.messages ?? []).enumerated().map { message($0.offset + 1, $0.element.0, $0.element.1, in: id) }
            // As the relay pages: newest first before a seq, oldest first after one.
            let role = query["role"]
            var rows = all.filter { row in role == nil || row["content"]?["v"]?["role"]?.stringValue == role }
            if let after = query["afterSeq"].flatMap(Int.init) {
                rows = rows.filter { ($0["seq"]?.intValue ?? 0) > after }
            } else {
                let before = query["beforeSeq"].flatMap(Int.init) ?? Int.max
                rows = rows.filter { ($0["seq"]?.intValue ?? 0) < before }.reversed()
            }
            let limit = query["limit"].flatMap(Int.init) ?? rows.count
            return (200, ["messages": .array(Array(rows.prefix(limit))), "hasMore": .bool(rows.count > limit)])
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

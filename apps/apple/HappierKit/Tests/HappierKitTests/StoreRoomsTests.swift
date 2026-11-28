import Foundation
import Testing
@testable import HappierKit

/// HTTP is the mocked boundary: an in-memory UserKVStore with versions, atomic mutations and bulk
/// reads (`kvRoutes.ts`), plus sessions' read state (`registerSessionReadStateRoutes.ts`); the
/// store's room logic, sealing and request building stay real.
private final class RoomKVServer: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: (value: String, version: Int)] = [:]
    private(set) var mutateCalls = 0
    /// The sessions marked read (`POST /v2/sessions/:id/read-state`), in order.
    private var reads: [String] = []
    var readSessions: [String] { lock.withLock { reads } }
    /// Listings of this prefix (and bulk reads, once `holdBulkReads()`) are answered, then their
    /// answer waits (a slow network) until `release()`, or 2 s at most.
    private var heldPrefix: String?
    private var holdsBulkReads = false
    private let held = DispatchSemaphore(value: 0)
    /// What happened, in order: the test's own marks and "held"/"released" for each held answer.
    private var log: [String] = []

    func hold(prefix: String) { lock.withLock { heldPrefix = prefix } }
    func holdBulkReads() { lock.withLock { holdsBulkReads = true } }
    func release() { held.signal() }
    func mark(_ event: String) { lock.withLock { log.append(event) } }
    var events: [String] { lock.withLock { log } }

    /// Whether the answer to `request` is held (`hold(prefix:)`, `holdBulkReads()`).
    func holds(_ request: URLRequest) -> Bool {
        let prefix = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "prefix" }?.value
        return lock.withLock {
            if request.httpMethod == "POST", request.url?.path == "/v1/kv/bulk" { return holdsBulkReads }
            guard request.httpMethod == "GET", let prefix, let heldPrefix else { return false }
            return prefix.hasPrefix(heldPrefix)
        }
    }

    /// A held answer waits here, after it was answered and before it arrives.
    func waitHeld() {
        mark("held")
        _ = held.wait(timeout: .now() + 2)
        mark("released")
    }

    func put(_ key: String, _ value: String, version: Int) { lock.withLock { rows[key] = (value, version) } }
    func remove(_ key: String) { lock.withLock { rows[key] = nil } }
    /// The keys of each bulk read (`POST /v1/kv/bulk`), in order.
    private var bulk: [[String]] = []
    var bulkReads: [[String]] { lock.withLock { bulk } }
    func row(_ key: String) -> (value: String, version: Int)? { lock.withLock { rows[key] } }

    func respond(_ request: URLRequest, _ body: Data) -> (Int, JSONValue) {
        lock.withLock {
            let path = request.url?.path ?? ""
            if request.httpMethod == "GET", path == "/v1/kv" {
                let prefix = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "prefix" }?.value ?? ""
                let items = rows.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }
                    .map { JSONValue.object(["key": .string($0.key), "value": .string($0.value.value), "version": .number(Double($0.value.version))]) }
                return (200, ["items": .array(items)])
            }
            guard let json = try? JSONValue.parse(body) else { return (400, [:]) }
            if request.httpMethod == "POST", path.hasPrefix("/v2/sessions/"), path.hasSuffix("/read-state") {
                guard json["state"]?.stringValue == "read" else { return (400, [:]) }
                reads.append(String(path.dropFirst("/v2/sessions/".count).dropLast("/read-state".count)))
                return (200, ["success": true])
            }
            if path == "/v1/kv/bulk" {
                let keys = (json["keys"]?.arrayValue ?? []).compactMap(\.stringValue)
                bulk.append(keys)
                let values = keys.compactMap { key -> JSONValue? in
                    rows[key].map { ["key": .string(key), "value": .string($0.value), "version": .number(Double($0.version))] }
                }
                return (200, ["values": .array(values)])
            }
            mutateCalls += 1
            let mutations = json["mutations"]?.arrayValue ?? []
            let conflicts = mutations.compactMap { mutation -> JSONValue? in
                guard let key = mutation["key"]?.stringValue, let version = mutation["version"]?.intValue else { return nil }
                let current = rows[key]?.version ?? -1
                guard current != version else { return nil }
                return ["key": .string(key), "error": "version-mismatch", "version": .number(Double(current)),
                        "value": rows[key].map { .string($0.value) } ?? .null]
            }
            if !conflicts.isEmpty { return (409, ["success": false, "errors": .array(conflicts)]) }
            var results: [JSONValue] = []
            for mutation in mutations {
                guard let key = mutation["key"]?.stringValue else { continue }
                let next = (rows[key]?.version ?? -1) + 1
                if let value = mutation["value"]?.stringValue { rows[key] = (value, next) } else { rows[key] = nil }
                results.append(["key": .string(key), "version": .number(Double(next))])
            }
            return (200, ["success": true, "results": .array(results)])
        }
    }
}

private final class RoomKVURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var server: RoomKVServer?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                body.append(contentsOf: bytes.prefix(count))
            }
        }
        let server = Self.server
        let (status, json) = server?.respond(request, body) ?? (500, [:])
        let arrive = { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: (try? json.encoded()) ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }
        // A held answer arrives later (a slow network), without holding up the requests made meanwhile.
        if let server, server.holds(request) {
            DispatchQueue.global().async { server.waitHeld(); arrive() }
        } else {
            arrive()
        }
    }

    override func stopLoading() {}
}

@Suite(.serialized) @MainActor struct StoreRoomsTests {
    let keys = try! AccountKeys(masterSecret: Data(0..<32))
    var machineKey: Data { keys.content.secretKey }

    private func store(_ server: RoomKVServer) -> HappierStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoomKVURLProtocol.self]
        RoomKVURLProtocol.server = server
        let api = HappierAPI(server: URL(string: "https://rooms.invalid")!, token: "t", session: URLSession(configuration: configuration))
        let store = HappierStore(server: URL(string: "https://rooms.invalid")!)
        store.installForTesting(api: api, keys: keys, snapshotDirectory: FileManager.default.temporaryDirectory.appending(path: "rooms-\(UUID().uuidString)")) { _, _ in [] }
        return store
    }

    private func seed(_ server: RoomKVServer, lastSeq: Int, version: Int) throws {
        var room = AgentRoomTests.room(["lastSeq": .number(Double(lastSeq))])
        room.lastSeq = lastSeq
        server.put(AgentRoom.kvKey(id: "r1"), try room.sealed(machineKey: machineKey), version: version)
        for seq in stride(from: 1, through: lastSeq, by: 1) {
            let author: JSONValue = seq == 3 ? AgentRoomTests.agent("a-mateo") : AgentRoomTests.user
            server.put(AgentRoomMessage.kvKey(roomId: "r1", seq: seq),
                       try AgentRoomTests.message(seq, by: author, text: "m\(seq)").sealed(machineKey: machineKey), version: 0)
        }
    }

    /// A member's seat as its daemon writes it: its thread and, while a turn runs, `inFlight`.
    private func seat(_ roomId: String, _ agentId: String, thread: String?, inFlight: Bool = false) throws -> String {
        var json: [String: JSONValue] = ["v": 1, "roomId": .string(roomId), "agentId": .string(agentId), "readThroughSeq": 1]
        if let thread { json["sessionId"] = .string(thread) }
        if inFlight { json["inFlight"] = ["throughSeq": 2, "at": 1] }
        return try AccountScopedBlob.seal(.object(json), kind: .agentRoom, machineKey: machineKey)
    }

    private func putSeat(_ server: RoomKVServer, _ roomId: String, _ agentId: String, thread: String?, inFlight: Bool = false) throws {
        server.put(AgentRoomSeat.kvKey(roomId: roomId, agentId: agentId), try seat(roomId, agentId, thread: thread, inFlight: inFlight), version: 0)
    }

    private func thread(_ id: String, unread: Bool) throws -> Session {
        var row: [String: JSONValue] = ["id": .string(id), "encryptionMode": "plain", "metadataVersion": 1, "active": true, "updatedAt": 10,
                                        "metadata": .string(#"{"path":"/p","flavor":"claude"}"#)]
        if unread { row["unreadSince"] = 7 }
        return try Session(row: .object(row), keys: nil)
    }

    @Test func theUsersMessageTakesTheNextSeqEvenWhenAnAgentWroteFirst() async throws {
        let server = RoomKVServer()
        try seed(server, lastSeq: 2, version: 5)
        let store = store(server)
        await store.refreshRooms()
        await store.loadRoom(id: "r1")
        #expect(store.roomMessages["r1"]?.map(\.seq) == [1, 2])

        // Mateo's daemon posts #3 meanwhile: this app still has the room at #2.
        try seed(server, lastSeq: 3, version: 6)
        #expect(await store.sendRoomMessage(roomId: "r1", text: "@Tomás sigue tú"))

        let room = try #require(server.row(AgentRoom.kvKey(id: "r1")).flatMap { AgentRoom.open($0.value, machineKey: machineKey) })
        #expect(room.lastSeq == 4)
        let sent = try #require(server.row(AgentRoomMessage.kvKey(roomId: "r1", seq: 4)).flatMap { AgentRoomMessage.open($0.value, machineKey: machineKey) })
        #expect(sent.author == .user)
        #expect(sent.mentions == ["a-tomas"])
        #expect(sent.text == "@Tomás sigue tú")
        // Mateo's #3 is kept, and this app shows it too once it reads the room again, behind the send.
        #expect(server.row(AgentRoomMessage.kvKey(roomId: "r1", seq: 3)) != nil)
        #expect(server.mutateCalls == 2)
        #expect(store.rooms.first { $0.id == "r1" }?.lastSeq == 4)
        for _ in 0..<100 where store.roomMessages["r1"]?.count != 4 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(store.roomMessages["r1"]?.map(\.seq) == [1, 2, 3, 4])
    }

    @Test func sendingIsDoneOnceTheMessageIsSavedNotOnceTheRoomIsReadAgain() async throws {
        let server = RoomKVServer()
        try seed(server, lastSeq: 3, version: 5)
        let store = store(server)
        await store.refreshRooms()
        await store.loadRoom(id: "r1")
        // Reading the room again after a send (its members' seats) is slow; the composer must not wait for it.
        server.hold(prefix: AgentRoomSeat.kvPrefix(roomId: "r1"))
        #expect(await store.sendRoomMessage(roomId: "r1", text: "@Tomás sigue tú"))
        server.mark("sent")
        #expect(store.roomMessages["r1"]?.last?.text == "@Tomás sigue tú")
        let quoted = try #require(store.roomMessages["r1"]?.first { $0.seq == 3 })
        #expect(await store.answerRoomOption(roomId: "r1", message: quoted, option: "Sí"))
        server.mark("answered")
        #expect(store.roomMessages["r1"]?.last?.text == "@Mateo Sí")
        for _ in 0..<2 { server.release() }
        // The room is still read again, behind the send.
        for _ in 0..<100 where server.events.filter({ $0 == "released" }).count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        let events = server.events
        #expect(events.firstIndex(of: "sent")! < events.firstIndex(of: "released")!)
        #expect(events.firstIndex(of: "answered")! < events.lastIndex(of: "released")!)
        #expect(server.mutateCalls == 2)
    }

    @Test func anAgentsChatIsMadeOnceAndStaysOutOfTheRooms() async throws {
        let server = RoomKVServer()
        try seed(server, lastSeq: 2, version: 5)
        let store = store(server)
        await store.refreshRooms()
        let mateo = AgentProfile(id: "a-mateo", name: "Mateo", providerId: "codex", account: .init(label: "ChatGPT"))
        let chat = try #require(await store.openDirectRoom(with: mateo, machineId: "m1", directory: "/p"))
        #expect(chat.directAgentId == "a-mateo")
        // It takes the name the user goes by in their rooms.
        #expect(chat.userName == "Manny")
        #expect(server.row(AgentRoom.kvKey(id: chat.id)) != nil)
        // Opened again, it is the same chat.
        let again = await store.openDirectRoom(with: mateo, machineId: "m1", directory: "/p")
        #expect(again?.id == chat.id)
        #expect(server.mutateCalls == 1)
        #expect(store.directRoom(agentId: "a-mateo")?.id == chat.id)
        #expect(store.activeRooms.map(\.id) == ["r1"])
        // Another device that hasn't read it yet finds it instead of making a second one.
        let other = self.store(server)
        #expect(await other.openDirectRoom(with: mateo, machineId: "m1", directory: "/p")?.id == chat.id)
        #expect(server.mutateCalls == 1)
        // Still empty, it moves to where it should work now; once written to, its agent's thread
        // lives there and it stays.
        let moved = await store.openDirectRoom(with: mateo, machineId: "m9", directory: "/home")
        #expect(moved?.id == chat.id && moved?.members.first?.machineId == "m9" && moved?.members.first?.directory == "/home")
        #expect(await store.sendRoomMessage(roomId: chat.id, text: "hola", replyingTo: nil))
        let kept = await store.openDirectRoom(with: mateo, machineId: "m1", directory: "/p")
        #expect(kept?.members.first?.machineId == "m9" && kept?.members.first?.directory == "/home")
    }

    @Test func aMembersAnswersOtherAgentsChangesInARoomAlreadyMade() async throws {
        let server = RoomKVServer()
        try seed(server, lastSeq: 2, version: 5)
        let store = store(server)
        await store.refreshRooms()
        // Tomás (stored without it) now answers other agents; Mateo keeps his.
        let updated = await store.setRoomMemberAnswersAgents(roomId: "r1", agentId: "a-tomas", true)
        #expect(updated?.members.first { $0.agentId == "a-tomas" }?.wakeByAgents == true)
        let room = try #require(server.row(AgentRoom.kvKey(id: "r1")).flatMap { AgentRoom.open($0.value, machineKey: machineKey) })
        #expect(room.members.map(\.wakeByAgents) == [true, true])
        #expect(room.lastSeq == 2)
    }

    @Test func theUsersNameInARoomChangesAndClearsWithoutTouchingTheRest() async throws {
        let server = RoomKVServer()
        try seed(server, lastSeq: 2, version: 5)
        let store = store(server)
        await store.refreshRooms()
        #expect(await store.setRoomUserName(roomId: "r1", "  Manny Ruiz ")?.userName == "Manny Ruiz")
        var stored = try #require(server.row(AgentRoom.kvKey(id: "r1")).flatMap { AgentRoom.open($0.value, machineKey: machineKey) })
        #expect(stored.userName == "Manny Ruiz")
        #expect(stored.lastSeq == 2 && stored.members.count == 2)
        // Empty: the agents go back to calling the user "User" (no name stored).
        _ = await store.setRoomUserName(roomId: "r1", " ")
        stored = try #require(server.row(AgentRoom.kvKey(id: "r1")).flatMap { AgentRoom.open($0.value, machineKey: machineKey) })
        #expect(stored.userName == nil)
        #expect(stored.json["userName"] == nil)
    }

    @Test func aDismissedWaitIsWrittenToTheRoomAndKeepsWhatOthersWrote() async throws {
        let server = RoomKVServer()
        try seed(server, lastSeq: 2, version: 5)
        let store = store(server)
        await store.refreshRooms()
        // Mateo's daemon posts #3 meanwhile; the dismissal is applied to that newer room.
        try seed(server, lastSeq: 3, version: 6)
        #expect(await store.dismissRoomWait(roomId: "r1", agentId: "a-tomas", mentionSeq: 2)?.members.last?.dismissedMentionSeq == 2)
        let room = try #require(server.row(AgentRoom.kvKey(id: "r1")).flatMap { AgentRoom.open($0.value, machineKey: machineKey) })
        #expect(room.lastSeq == 3)
        #expect(room.members.map(\.dismissedMentionSeq) == [nil, 2])
        #expect(room.members.map(\.wakeByAgents) == [true, nil])
    }

    @Test func aReplyIsWrittenAnsweringTheQuotedMessageAndReachesOnlyItsAuthor() async throws {
        let server = RoomKVServer()
        try seed(server, lastSeq: 3, version: 5)
        let store = store(server)
        await store.refreshRooms()
        await store.loadRoom(id: "r1")
        let quoted = try #require(store.roomMessages["r1"]?.first { $0.seq == 3 })
        #expect(await store.sendRoomMessage(roomId: "r1", text: "sí, hazlo", replyingTo: quoted))
        let sent = try #require(server.row(AgentRoomMessage.kvKey(roomId: "r1", seq: 4)).flatMap { AgentRoomMessage.open($0.value, machineKey: machineKey) })
        #expect(sent.text == "sí, hazlo")
        #expect(sent.replyTo == 3)
        #expect(sent.mentions == ["a-mateo"])
    }

    @Test func pausingWritesTheRoomAtItsVersionAndKeepsTheOthersChanges() async throws {
        let server = RoomKVServer()
        try seed(server, lastSeq: 2, version: 5)
        let store = store(server)
        await store.refreshRooms()
        try seed(server, lastSeq: 3, version: 6)
        let paused = await store.setRoomPaused(id: "r1", true)
        #expect(paused?.isPaused == true)
        let room = try #require(server.row(AgentRoom.kvKey(id: "r1")).flatMap { AgentRoom.open($0.value, machineKey: machineKey) })
        #expect(room.isPaused)
        #expect(room.lastSeq == 3)
    }

    @Test func everyRoomsThreadsAreKnownWithoutOpeningTheRoom() async throws {
        let server = RoomKVServer()
        try seed(server, lastSeq: 2, version: 5)
        let mateo = AgentProfile(id: "a-mateo", name: "Mateo", providerId: "codex", account: .init(label: "ChatGPT"))
        let chat = AgentRoom.direct(with: mateo, machineId: "m1", directory: "/p", userName: "Manny", now: 1)
        server.put(AgentRoom.kvKey(id: chat.id), try chat.sealed(machineKey: machineKey), version: 0)
        let archived = AgentRoomTests.room(["id": "r-old", "archivedAt": 3])
        server.put(AgentRoom.kvKey(id: "r-old"), try archived.sealed(machineKey: machineKey), version: 0)
        try putSeat(server, "r1", "a-tomas", thread: "g1")
        // Mentioned but not started yet: no thread.
        try putSeat(server, "r1", "a-mateo", thread: nil)
        try putSeat(server, chat.id, "a-mateo", thread: "d1", inFlight: true)
        try putSeat(server, "r-old", "a-tomas", thread: "old1")
        let store = store(server)
        await store.refreshRooms()
        // No room was opened: the seats come with the rooms.
        #expect(store.roomMessages.isEmpty)
        #expect(store.roomSeats["r1"]?.count == 2)
        #expect(store.roomThreads == [
            "g1": AgentRoomThread(selection: AgentRoom.selection(id: "r1"), inFlight: false),
            "d1": AgentRoomThread(selection: AgentProfile.selection(id: "a-mateo"), inFlight: true),
        ])
        // Its daemon starts the chat again on a new thread: the change alone tells.
        _ = store.applyRoomChange(.init(key: AgentRoomSeat.kvKey(roomId: chat.id, agentId: "a-mateo"),
                                        value: try seat(chat.id, "a-mateo", thread: "d2"), version: 1), machineKey: machineKey)
        #expect(store.roomThreads["d1"] == nil)
        #expect(store.roomThreads["d2"] == AgentRoomThread(selection: AgentProfile.selection(id: "a-mateo"), inFlight: false))
        // A room made on another device after the listing takes its first seat from the changes too.
        let made = AgentRoomTests.room(["id": "r3"])
        _ = store.applyRoomChange(.init(key: AgentRoom.kvKey(id: "r3"), value: try made.sealed(machineKey: machineKey), version: 0),
                                  machineKey: machineKey)
        _ = store.applyRoomChange(.init(key: AgentRoomSeat.kvKey(roomId: "r3", agentId: "a-tomas"),
                                        value: try seat("r3", "a-tomas", thread: "g3"), version: 0), machineKey: machineKey)
        #expect(store.roomThreads["g3"] == AgentRoomThread(selection: AgentRoom.selection(id: "r3"), inFlight: false))
    }

    @Test func readingARoomReadsItsUnreadThreads() async throws {
        let server = RoomKVServer()
        try seed(server, lastSeq: 2, version: 5)
        try putSeat(server, "r1", "a-tomas", thread: "t1")
        try putSeat(server, "r1", "a-mateo", thread: "t2")
        let store = store(server)
        await store.refreshRooms()
        store.sessions["t1"] = try thread("t1", unread: true)
        store.sessions["t2"] = try thread("t2", unread: false)
        #expect(store.unreadRoomThreads(roomId: "r1") == ["t1"])
        store.readRoomThreads(roomId: "r1")
        #expect(store.sessions["t1"]?.unreadSince == nil)
        #expect(store.unreadRoomThreads(roomId: "r1").isEmpty)
        for _ in 0..<100 where server.readSessions.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(server.readSessions == ["t1"])
        // Read already: nothing more is written.
        store.readRoomThreads(roomId: "r1")
        try await Task.sleep(for: .milliseconds(100))
        #expect(server.readSessions == ["t1"])
    }

    // MARK: What waits for the agent in its chat

    /// Mateo's seat in his chat as his daemon writes it, with what this build doesn't read (the
    /// delivery's `localId` and `sent`, `updatedAt`, a newer build's field).
    private func chatSeat(_ chatId: String, read: Int, inFlight: [String: JSONValue]?) throws -> String {
        var json: [String: JSONValue] = ["v": 1, "roomId": .string(chatId), "agentId": "a-mateo", "sessionId": "d1",
                                         "readThroughSeq": .number(Double(read)), "updatedAt": 9, "futureField": ["x": 1]]
        if let inFlight { json["inFlight"] = .object(inFlight) }
        return try AccountScopedBlob.seal(.object(json), kind: .agentRoom, machineKey: machineKey)
    }

    /// The user's message in Mateo's chat, as stored; #2 answers #1 and has a newer build's field.
    private func chatMessage(_ chatId: String, _ seq: Int, text: String) throws -> String {
        var json: [String: JSONValue] = ["v": 1, "roomId": .string(chatId), "seq": .number(Double(seq)), "at": .number(Double(seq * 10)),
                                         "author": AgentRoomTests.user, "text": .string(text), "mentions": ["a-mateo"]]
        if seq == 2 {
            json["replyTo"] = ["seq": 1]
            json["futureField"] = "kept"
        }
        return try AccountScopedBlob.seal(.object(json), kind: .agentRoom, machineKey: machineKey)
    }

    /// Mateo's chat with the user's #1, #2 (answering #1, with a newer build's field) and #3; his
    /// daemon took #1 for the turn he's working (not sent yet), so #2 and #3 wait. The seat is at version 4.
    private func seedChat(_ server: RoomKVServer) throws -> (chat: AgentRoom, seat: String) {
        let mateo = AgentProfile(id: "a-mateo", name: "Mateo", providerId: "codex", account: .init(label: "ChatGPT"))
        var chat = AgentRoom.direct(with: mateo, machineId: "m1", directory: "/p", userName: "Manny", now: 1)
        chat.lastSeq = 3
        server.put(AgentRoom.kvKey(id: chat.id), try chat.sealed(machineKey: machineKey), version: 3)
        for seq in 1...3 {
            server.put(AgentRoomMessage.kvKey(roomId: chat.id, seq: seq), try chatMessage(chat.id, seq, text: "m\(seq)"), version: 0)
        }
        let seat = try chatSeat(chat.id, read: 0, inFlight: ["localId": "room.c.a-mateo.n1", "throughSeq": 1, "at": 5])
        server.put(AgentRoomSeat.kvKey(roomId: chat.id, agentId: "a-mateo"), seat, version: 4)
        return (chat, seat)
    }

    private func openChat(_ server: RoomKVServer, _ chat: AgentRoom) async -> HappierStore {
        let store = store(server)
        await store.refreshRooms()
        await store.loadRoom(id: chat.id)
        return store
    }

    @Test func withdrawingAQueuedMessageDeletesItAndWritesTheSeatBackUnchanged() async throws {
        let server = RoomKVServer()
        let (chat, seat) = try seedChat(server)
        let store = await openChat(server, chat)
        let queue = try #require(store.room(id: chat.id)?.queued(seats: store.roomSeats[chat.id] ?? [], messages: store.roomMessages[chat.id] ?? []))
        #expect(queue.messages.map(\.seq) == [2, 3] && queue.reason == .afterCurrentTurn && queue.revisable)

        #expect(await store.reviseQueuedRoomMessage(roomId: chat.id, seq: 2, .cancel) == .done)
        #expect(server.row(AgentRoomMessage.kvKey(roomId: chat.id, seq: 2)) == nil)
        // The seat is only the guard: written back byte for byte (never resealed from the model), one version on.
        let written = try #require(server.row(AgentRoomSeat.kvKey(roomId: chat.id, agentId: "a-mateo")))
        #expect(written.value == seat)
        #expect(written.version == 5)
        #expect(server.mutateCalls == 1)
        #expect(store.roomMessages[chat.id]?.map(\.seq) == [1, 3])
        #expect(server.row(AgentRoomMessage.kvKey(roomId: chat.id, seq: 3)) != nil)
    }

    @Test func aMessageTheAgentAlreadyGotIsNotWithdrawn() async throws {
        let server = RoomKVServer()
        let (chat, _) = try seedChat(server)
        let store = await openChat(server, chat)
        // Meanwhile Mateo's turn ended and his daemon took #2 and #3 for the next one.
        let taken = try chatSeat(chat.id, read: 1, inFlight: ["localId": "room.c.a-mateo.n2", "throughSeq": 3, "at": 6])
        server.put(AgentRoomSeat.kvKey(roomId: chat.id, agentId: "a-mateo"), taken, version: 6)
        let before = try #require(server.row(AgentRoomMessage.kvKey(roomId: chat.id, seq: 2)))

        #expect(await store.reviseQueuedRoomMessage(roomId: chat.id, seq: 2, .cancel) == .alreadyDelivered)
        #expect(server.row(AgentRoomMessage.kvKey(roomId: chat.id, seq: 2))?.value == before.value)
        #expect(server.row(AgentRoomSeat.kvKey(roomId: chat.id, agentId: "a-mateo"))?.version == 6)
        #expect(store.roomMessages[chat.id]?.map(\.seq) == [1, 2, 3])
        // What the agent has now is shown: nothing waits any more.
        #expect(store.room(id: chat.id)?.queued(seats: store.roomSeats[chat.id] ?? [], messages: store.roomMessages[chat.id] ?? []) == nil)
    }

    @Test func withdrawingGoesAgainWhenTheSeatChangedWithoutReadingTheMessage() async throws {
        let server = RoomKVServer()
        let (chat, _) = try seedChat(server)
        let store = await openChat(server, chat)
        let seatKey = AgentRoomSeat.kvKey(roomId: chat.id, agentId: "a-mateo")
        // The turn's delivery was sent: the seat moved, but #2 still waits.
        let sent = try chatSeat(chat.id, read: 0, inFlight: ["localId": "room.c.a-mateo.n1", "throughSeq": 1, "at": 5, "sent": true])
        server.put(seatKey, sent, version: 5)
        #expect(await store.reviseQueuedRoomMessage(roomId: chat.id, seq: 2, .cancel) == .done)
        #expect(server.row(AgentRoomMessage.kvKey(roomId: chat.id, seq: 2)) == nil)
        #expect(server.row(seatKey)?.value == sent && server.row(seatKey)?.version == 6)
        #expect(server.mutateCalls == 2)
        // The turn ended, its marker at #1: #3 still waits.
        let ended = try chatSeat(chat.id, read: 1, inFlight: nil)
        server.put(seatKey, ended, version: 9)
        #expect(await store.reviseQueuedRoomMessage(roomId: chat.id, seq: 3, .cancel) == .done)
        #expect(server.row(AgentRoomMessage.kvKey(roomId: chat.id, seq: 3)) == nil)
        #expect(server.row(seatKey)?.value == ended && server.row(seatKey)?.version == 10)
        #expect(store.roomMessages[chat.id]?.map(\.seq) == [1])
    }

    @Test func editingAQueuedMessageRewritesItAtItsSeq() async throws {
        let server = RoomKVServer()
        let (chat, seat) = try seedChat(server)
        let store = await openChat(server, chat)
        #expect(await store.reviseQueuedRoomMessage(roomId: chat.id, seq: 2, .edit("  mejor esto  ")) == .done)
        let row = try #require(server.row(AgentRoomMessage.kvKey(roomId: chat.id, seq: 2)))
        #expect(row.version == 1)
        let edited = try #require(AgentRoomMessage.open(row.value, machineKey: machineKey))
        #expect(edited.text == "mejor esto")
        #expect(edited.seq == 2 && edited.at == 20 && edited.author == .user)
        #expect(edited.mentions == ["a-mateo"] && edited.replyTo == 1)
        #expect(edited.json["futureField"] == "kept")
        let written = try #require(server.row(AgentRoomSeat.kvKey(roomId: chat.id, agentId: "a-mateo")))
        #expect(written.value == seat && written.version == 5)
        #expect(store.roomMessages[chat.id]?.first { $0.seq == 2 }?.text == "mejor esto")
        // Edited again from what was saved.
        #expect(await store.reviseQueuedRoomMessage(roomId: chat.id, seq: 2, .edit("y esto")) == .done)
        #expect(server.row(AgentRoomMessage.kvKey(roomId: chat.id, seq: 2))?.version == 2)
        #expect(server.mutateCalls == 2)
    }

    @Test func sendingAWaitingMessageNowFlagsItAndWritesTheSeatBackUnchanged() async throws {
        let server = RoomKVServer()
        let (chat, _) = try seedChat(server)
        let seatKey = AgentRoomSeat.kvKey(roomId: chat.id, agentId: "a-mateo")
        // Mateo's turn runs with #1 and #2 (sent into it past #1's delivery), from a daemon that takes
        // what is sent now: #3 waits.
        let seat = try chatSeat(chat.id, read: 0, inFlight: ["localId": "room.c.a-mateo.n2", "throughSeq": 2, "at": 6, "sent": true,
                                                             "sendNowSupported": true,
                                                             "steers": ["localId": "room.c.a-mateo.n1", "throughSeq": 1]])
        server.put(seatKey, seat, version: 4)
        let store = await openChat(server, chat)
        let queue = try #require(store.room(id: chat.id)?.queued(seats: store.roomSeats[chat.id] ?? [], messages: store.roomMessages[chat.id] ?? []))
        #expect(queue.messages.map(\.seq) == [3] && queue.sendNowSupported)

        #expect(await store.reviseQueuedRoomMessage(roomId: chat.id, seq: 3, .sendNow) == .done)
        let row = try #require(server.row(AgentRoomMessage.kvKey(roomId: chat.id, seq: 3)))
        #expect(row.version == 1)
        let flagged = try #require(AgentRoomMessage.open(row.value, machineKey: machineKey))
        #expect(flagged.sendNow)
        #expect(flagged.text == "m3" && flagged.seq == 3 && flagged.at == 30 && flagged.mentions == ["a-mateo"])
        // The seat only guards the write: byte for byte as the daemon wrote it (its delivery, the one it
        // was sent past, its stamp), one version on.
        let written = try #require(server.row(seatKey))
        #expect(written.value == seat && written.version == 5)
        #expect(server.mutateCalls == 1)
        let shown = try #require(store.room(id: chat.id)?.queued(seats: store.roomSeats[chat.id] ?? [], messages: store.roomMessages[chat.id] ?? []))
        #expect(shown.messages.map(\.seq) == [3] && shown.sendingNowThroughSeq == 3)
    }

    @Test func sendingNowAMessageTheAgentAlreadyHasChangesNothing() async throws {
        let server = RoomKVServer()
        let (chat, _) = try seedChat(server)
        let store = await openChat(server, chat)
        let seatKey = AgentRoomSeat.kvKey(roomId: chat.id, agentId: "a-mateo")
        let key2 = AgentRoomMessage.kvKey(roomId: chat.id, seq: 2), key3 = AgentRoomMessage.kvKey(roomId: chat.id, seq: 3)
        // Meanwhile Mateo's daemon took #2 (into his running turn, or the next one).
        server.put(seatKey, try chatSeat(chat.id, read: 0, inFlight: ["localId": "room.c.a-mateo.n2", "throughSeq": 2, "at": 6,
                                                                       "sendNowSupported": true]), version: 6)
        let before = try #require(server.row(key2))
        #expect(await store.reviseQueuedRoomMessage(roomId: chat.id, seq: 2, .sendNow) == .alreadyDelivered)
        #expect(server.row(key2)?.value == before.value && server.row(key2)?.version == 0)
        #expect(server.row(seatKey)?.version == 6)
        // Another device sent #3 now first: this one finds it so and is done.
        server.put(key3, try AccountScopedBlob.seal(["v": 1, "roomId": .string(chat.id), "seq": 3, "at": 30, "author": AgentRoomTests.user,
                                                     "text": "m3", "mentions": ["a-mateo"], "sendNow": true],
                                                    kind: .agentRoom, machineKey: machineKey), version: 1)
        #expect(await store.reviseQueuedRoomMessage(roomId: chat.id, seq: 3, .sendNow) == .done)
        #expect(server.row(key3)?.version == 1 && server.row(seatKey)?.version == 6)
        #expect(store.roomMessages[chat.id]?.first { $0.seq == 3 }?.sendNow == true)
        // Sent now already: a second tap writes nothing.
        let calls = server.mutateCalls
        #expect(await store.reviseQueuedRoomMessage(roomId: chat.id, seq: 3, .sendNow) == .done)
        #expect(server.mutateCalls == calls)
    }

    @Test func aMessageWithdrawnOnAnotherDeviceLeavesTheChat() async throws {
        let server = RoomKVServer()
        let (chat, _) = try seedChat(server)
        let store = await openChat(server, chat)
        let key = AgentRoomMessage.kvKey(roomId: chat.id, seq: 2)
        // An edit made there arrives; an older copy arriving late doesn't undo it.
        _ = store.applyRoomChange(.init(key: key, value: try chatMessage(chat.id, 2, text: "otra cosa"), version: 1), machineKey: machineKey)
        let older = try #require(server.row(key))
        _ = store.applyRoomChange(.init(key: key, value: older.value, version: 0), machineKey: machineKey)
        #expect(store.roomMessages[chat.id]?.first { $0.seq == 2 }?.text == "otra cosa")
        // Withdrawn there.
        _ = store.applyRoomChange(.init(key: key, value: nil, version: 2), machineKey: machineKey)
        #expect(store.roomMessages[chat.id]?.map(\.seq) == [1, 3])
    }

    @Test func loadRoomDropsAQueuedMessageWithdrawnWhileThisDeviceWasAway() async throws {
        let server = RoomKVServer()
        let (chat, _) = try seedChat(server)
        let store = await openChat(server, chat)
        // Away: another device withdraws #2 and edits #3, then #3 reaches Mateo and his turn ends.
        server.put(AgentRoomSeat.kvKey(roomId: chat.id, agentId: "a-mateo"), try chatSeat(chat.id, read: 3, inFlight: nil), version: 8)
        server.put(AgentRoomMessage.kvKey(roomId: chat.id, seq: 3), try chatMessage(chat.id, 3, text: "m3 bis"), version: 1)
        server.remove(AgentRoomMessage.kvKey(roomId: chat.id, seq: 2))
        // Back: the catch-up reads the rooms (and their seats), then the open room.
        await store.refreshRooms()
        await store.loadRoom(id: chat.id)
        #expect(store.roomMessages[chat.id]?.map(\.seq) == [1, 3])
        #expect(store.roomMessages[chat.id]?.last?.text == "m3 bis")
        // Mateo has everything now: what this device holds is final, so only the withdrawn #2 (still
        // missing from the window) is asked for again.
        await store.loadRoom(id: chat.id)
        #expect(server.bulkReads.last == [AgentRoomMessage.kvKey(roomId: chat.id, seq: 2)])
    }

    private func waitForHeld(_ server: RoomKVServer, count: Int) async throws {
        for _ in 0..<100 where server.events.filter({ $0 == "held" }).count < count { try await Task.sleep(for: .milliseconds(20)) }
        #expect(server.events.filter { $0 == "held" }.count == count)
    }

    /// The seats are listed before the messages are read: a seat written meanwhile (the daemon taking
    /// the message just sent) arrives as a change and is newer than the listing, so it stays; so does
    /// a seat the listing predates. The same for every room's seats, read with the rooms.
    @Test func aSeatWrittenWhileTheSeatsAreReadStays() async throws {
        let server = RoomKVServer()
        let (chat, _) = try seedChat(server)
        // A group room where nobody was mentioned yet: no seats.
        try seed(server, lastSeq: 2, version: 5)
        let store = await openChat(server, chat)
        let seatKey = AgentRoomSeat.kvKey(roomId: chat.id, agentId: "a-mateo")

        // The chat is read again (behind a send): its seat (version 4) was listed when Mateo's daemon
        // takes #2 and #3 for his next turn.
        server.hold(prefix: AgentRoomSeat.kvPrefix(roomId: chat.id))
        let load = Task { await store.loadRoom(id: chat.id) }
        try await waitForHeld(server, count: 1)
        let taken = try chatSeat(chat.id, read: 1, inFlight: ["localId": "room.c.a-mateo.n2", "throughSeq": 3, "at": 6])
        _ = store.applyRoomChange(.init(key: seatKey, value: taken, version: 6), machineKey: machineKey)
        server.release()
        await load.value
        #expect(store.roomSeats[chat.id]?.map(\.version) == [6])
        // Mateo has them: nothing shows as waiting.
        #expect(store.room(id: chat.id)?.queued(seats: store.roomSeats[chat.id] ?? [], messages: store.roomMessages[chat.id] ?? []) == nil)

        // The rooms are read again: Mateo's turn is sent and Tomás takes his first mention in r1 after
        // every room's seats were listed.
        server.hold(prefix: AgentRoomSeat.kvPrefix)
        let refresh = Task { await store.refreshRooms() }
        try await waitForHeld(server, count: 2)
        let sent = try chatSeat(chat.id, read: 1, inFlight: ["localId": "room.c.a-mateo.n2", "throughSeq": 3, "at": 6, "sent": true])
        _ = store.applyRoomChange(.init(key: seatKey, value: sent, version: 7), machineKey: machineKey)
        _ = store.applyRoomChange(.init(key: AgentRoomSeat.kvKey(roomId: "r1", agentId: "a-tomas"),
                                        value: try seat("r1", "a-tomas", thread: "g1"), version: 0), machineKey: machineKey)
        server.release()
        await refresh.value
        #expect(store.roomSeats[chat.id]?.map(\.version) == [7])
        #expect(store.roomThreads["d1"] == AgentRoomThread(selection: AgentProfile.selection(id: "a-mateo"), inFlight: true))
        #expect(store.roomThreads["g1"] == AgentRoomThread(selection: AgentRoom.selection(id: "r1"), inFlight: false))
    }

    /// A message withdrawn while the chat is read again doesn't come back with a read answered before
    /// it went: a seq is never used again, so one removed here stays removed. Whether it was withdrawn
    /// here, or on another device before this one had it.
    @Test func aMessageWithdrawnWhileTheChatIsReadDoesNotComeBack() async throws {
        let server = RoomKVServer()
        var (chat, _) = try seedChat(server)
        let store = await openChat(server, chat)
        // The chat is read again (behind a send): #2 and #3 still wait, so they are read again too.
        server.holdBulkReads()
        let load = Task { await store.loadRoom(id: chat.id) }
        try await waitForHeld(server, count: 1)
        #expect(await store.reviseQueuedRoomMessage(roomId: chat.id, seq: 2, .cancel) == .done)
        #expect(store.roomMessages[chat.id]?.map(\.seq) == [1, 3])
        server.release()
        await load.value
        #expect(store.roomMessages[chat.id]?.map(\.seq) == [1, 3])

        // The user sends #4 from another device, which withdraws it while this one reads it.
        chat.lastSeq = 4
        server.put(AgentRoom.kvKey(id: chat.id), try chat.sealed(machineKey: machineKey), version: 4)
        let fourth = AgentRoomMessage.kvKey(roomId: chat.id, seq: 4)
        server.put(fourth, try chatMessage(chat.id, 4, text: "m4"), version: 0)
        await store.refreshRooms()
        let again = Task { await store.loadRoom(id: chat.id) }
        try await waitForHeld(server, count: 2)
        #expect(server.bulkReads.last?.contains(fourth) == true)
        server.remove(fourth)
        _ = store.applyRoomChange(.init(key: fourth, value: nil, version: 1), machineKey: machineKey)
        server.release()
        await again.value
        #expect(store.roomMessages[chat.id]?.map(\.seq) == [1, 3])
    }

    /// The same on the chat's first read, before this device holds any of its messages.
    @Test func aMessageWithdrawnWhileTheChatIsFirstReadDoesNotComeBack() async throws {
        let server = RoomKVServer()
        let (chat, _) = try seedChat(server)
        let store = store(server)
        await store.refreshRooms()
        #expect(store.roomMessages[chat.id] == nil)
        server.holdBulkReads()
        let load = Task { await store.loadRoom(id: chat.id) }
        try await waitForHeld(server, count: 1)
        let third = AgentRoomMessage.kvKey(roomId: chat.id, seq: 3)
        server.remove(third)
        _ = store.applyRoomChange(.init(key: third, value: nil, version: 1), machineKey: machineKey)
        server.release()
        await load.value
        #expect(store.roomMessages[chat.id]?.map(\.seq) == [1, 2])
    }
}

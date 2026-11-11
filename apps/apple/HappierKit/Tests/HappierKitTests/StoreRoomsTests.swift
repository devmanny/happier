import Foundation
import Testing
@testable import HappierKit

/// HTTP is the mocked boundary: an in-memory UserKVStore with versions, atomic mutations and bulk
/// reads (`kvRoutes.ts`); the store's room logic, sealing and request building stay real.
private final class RoomKVServer: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: (value: String, version: Int)] = [:]
    private(set) var mutateCalls = 0

    func put(_ key: String, _ value: String, version: Int) { lock.withLock { rows[key] = (value, version) } }
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
            if path == "/v1/kv/bulk" {
                let values = (json["keys"]?.arrayValue ?? []).compactMap(\.stringValue).compactMap { key -> JSONValue? in
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
        let (status, json) = Self.server?.respond(request, body) ?? (500, [:])
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? json.encoded()) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
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
        // Mateo's #3 is kept, and this app shows it too.
        #expect(server.row(AgentRoomMessage.kvKey(roomId: "r1", seq: 3)) != nil)
        #expect(server.mutateCalls == 2)
        #expect(store.rooms.first { $0.id == "r1" }?.lastSeq == 4)
        #expect(store.roomMessages["r1"]?.map(\.seq) == [1, 2, 3, 4])
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
}

import Foundation
import Testing
@testable import HappierKit

/// Session groups are the account's session organization folders (`/v2/session-organization`,
/// feature `sessions.folders`); HTTP is the mocked boundary, the store's sealing and requests stay real.
private final class OrganizationServer: @unchecked Sendable {
    private let lock = NSLock()
    private var folders: [String: JSONValue] = [:]
    private var assignments: [String: String] = [:]
    private var log: [String] = []
    var foldersEnabled = true
    var plainAccount = false
    /// Sessions the relay no longer has: moving one answers 404.
    var goneSessions: Set<String> = []
    private var holding = false
    private var holdingSave = false
    private var heldCount = 0
    /// Saving a group (`POST folders`) answers 500.
    var refusesSaves = false
    private let held = DispatchSemaphore(value: 0)

    /// Moves (`PUT folder-assignments`) wait until `release` while held.
    func holdMoves() { lock.withLock { holding = true } }
    /// The next group save (`POST folders`) waits until `release`.
    func holdNextSave() { lock.withLock { holdingSave = true } }
    var heldMoves: Int { lock.withLock { heldCount } }
    func release() {
        let count = lock.withLock { () -> Int in
            holding = false
            return heldCount
        }
        for _ in 0..<count { held.signal() }
    }
    /// Whether the request waits for `release`; then `wait` returns once it does.
    func holds(_ request: URLRequest) -> Bool {
        lock.withLock { () -> Bool in
            if holdingSave, request.httpMethod == "POST" {
                holdingSave = false
                heldCount += 1
                return true
            }
            guard holding, request.httpMethod == "PUT" else { return false }
            heldCount += 1
            return true
        }
    }
    func wait() { held.wait() }

    /// Each request as "METHOD path", in order.
    var requests: [String] { lock.withLock { log } }
    func folder(_ id: String) -> JSONValue? { lock.withLock { folders[id] } }
    func group(of sessionId: String) -> String? { lock.withLock { assignments[sessionId] } }

    func seed(folder: JSONValue, assigned sessionIds: [String] = []) {
        lock.withLock {
            let id = folder["folderId"]!.stringValue!
            folders[id] = folder
            for sessionId in sessionIds { assignments[sessionId] = id }
        }
    }

    func remove(folder id: String) {
        lock.withLock { folders[id] = nil }
    }

    func respond(_ request: URLRequest, _ body: Data) -> (Int, JSONValue) {
        lock.withLock {
            let path = request.url!.path
            let method = request.httpMethod ?? "GET"
            log.append("\(method) \(path)")
            switch (method, path) {
            case ("GET", "/v1/features"):
                return (200, ["features": ["sessions": ["enabled": true, "folders": ["enabled": .bool(foldersEnabled)]]]])
            case ("GET", "/v1/account/encryption"):
                return (200, ["mode": plainAccount ? "plain" : "e2ee", "updatedAt": 1])
            case ("GET", "/v2/session-organization"):
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                // Without `includeAllFolderAssignments` the relay answers no assignments at all.
                let all = query.contains { $0.name == "includeAllFolderAssignments" && $0.value == "true" }
                let rows: [JSONValue] = all ? assignments.sorted { $0.key < $1.key }.map { ["sessionId": .string($0.key), "folderId": .string($0.value)] } : []
                return (200, ["snapshot": ["schemaVersion": 1, "version": 3, "pins": [["sessionId": "p1", "sortKey": .null, "pinnedAt": 1]],
                                           "folders": .array(folders.values.sorted { $0["folderId"]!.stringValue! < $1["folderId"]!.stringValue! }),
                                           "folderAssignments": .array(rows), "tags": [], "tagAssignments": [], "orderEntries": [], "labels": []]])
            case ("POST", "/v2/session-organization/folders"):
                if refusesSaves { return (500, ["error": "internal"]) }
                guard let json = try? JSONValue.parse(body), let id = json["folderId"]?.stringValue else { return (400, ["error": "invalid-params"]) }
                var folder = json.objectValue ?? [:]
                folder["archivedAt"] = .null
                folder["createdAt"] = 1
                folder["updatedAt"] = 1
                folders[id] = .object(folder)
                return (200, ["folder": .object(folder)])
            case ("PUT", _) where path.hasPrefix("/v2/session-organization/folder-assignments/"):
                let sessionId = String(path.dropFirst("/v2/session-organization/folder-assignments/".count))
                if goneSessions.contains(sessionId) { return (404, ["error": "session-not-found"]) }
                guard let json = try? JSONValue.parse(body), let target = json["folderId"] else { return (400, ["error": "invalid-params"]) }
                if let folderId = target.stringValue {
                    guard folders[folderId] != nil else { return (400, ["error": "invalid-session-folder-assignment"]) }
                    assignments[sessionId] = folderId
                } else {
                    assignments[sessionId] = nil
                }
                return (200, ["sessionId": .string(sessionId), "folderId": target])
            case ("DELETE", _) where path.hasPrefix("/v2/session-organization/folders/"):
                let id = String(path.dropFirst("/v2/session-organization/folders/".count))
                folders[id] = nil
                let moved = assignments.filter { $0.value == id }.map(\.key)
                for sessionId in moved { assignments[sessionId] = nil }
                return (200, ["deletedFolderIds": [.string(id)], "assignmentTargetFolderId": .null, "affectedAssignmentCount": .number(Double(moved.count))])
            default:
                return (404, ["error": "not simulated"])
            }
        }
    }
}

private final class OrganizationURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var server: OrganizationServer?

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
        guard let server = Self.server, server.holds(request) else { return finish(body) }
        // Answered later, without blocking the session's other requests.
        DispatchQueue.global().async { [self] in
            server.wait()
            finish(body)
        }
    }

    private func finish(_ body: Data) {
        let (status, json) = Self.server?.respond(request, body) ?? (500, [:])
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? json.encoded()) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) @MainActor struct SessionGroupsTests {
    let keys = try! AccountKeys(masterSecret: Data(0..<32))
    var machineKey: Data { keys.content.secretKey }

    private func store(_ server: OrganizationServer) -> HappierStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OrganizationURLProtocol.self]
        OrganizationURLProtocol.server = server
        let api = HappierAPI(server: URL(string: "https://groups.invalid")!, token: "t", session: URLSession(configuration: configuration))
        let store = HappierStore(server: URL(string: "https://groups.invalid")!)
        store.installForTesting(api: api, keys: keys, snapshotDirectory: FileManager.default.temporaryDirectory.appending(path: "groups-\(UUID().uuidString)")) { _, _ in [] }
        return store
    }

    /// A folder as the relay lists it; `name` sealed for the account unless `plain`.
    private func folder(_ id: String, _ payload: JSONValue?, parent: String? = nil, sortKey: String? = nil, plain: Bool = false,
                        key: Data? = nil) throws -> JSONValue {
        let display: JSONValue = try payload.map { payload in
            plain ? ["t": "plain", "v": payload]
                : ["t": "encrypted", "c": .string(try AccountScopedBlob.seal(payload, kind: .sessionOrganizationDisplay, machineKey: key ?? machineKey))]
        } ?? .null
        return ["folderId": .string(id), "folderKey": .string(id), "parentFolderId": parent.map(JSONValue.string) ?? .null,
                "parentFolderKey": parent.map(JSONValue.string) ?? .null, "sortKey": sortKey.map(JSONValue.string) ?? .null,
                "display": display, "archivedAt": .null, "createdAt": 1, "updatedAt": 1]
    }

    /// The name a stored folder opens to, as another device of the account reads it.
    private func name(of folder: JSONValue?) -> String? {
        guard let display = folder?["display"] else { return nil }
        if display["t"]?.stringValue == "plain" { return display["v"]?["name"]?.stringValue }
        return display["c"]?.stringValue.flatMap { AccountScopedBlob.open($0, kind: .sessionOrganizationDisplay, machineKey: machineKey) }?["name"]?.stringValue
    }

    @Test func groupsComeFromTheAccountWithTheirNamesInOrder() async throws {
        let server = OrganizationServer()
        server.seed(folder: try folder("g-radar", ["name": "Radar"], plain: true), assigned: ["s1"])
        // Made in the web app: under a project, in its own order.
        server.seed(folder: try folder("g-kelpi", ["name": "Kelpi", "workspace": ["t": "workspaceScope", "serverId": "srv", "machineId": "m1", "rootPath": "/Users/manny/kelpi"]],
                                       sortKey: "a0"))
        server.seed(folder: try folder("g-kelpi-design", ["name": "Diseño"], parent: "g-kelpi"), assigned: ["s2"])
        // Sealed by another account, and one without a name: not groups anyone can read.
        server.seed(folder: try folder("g-foreign", ["name": "Ajeno"], key: Data(repeating: 7, count: 32)), assigned: ["s3"])
        server.seed(folder: try folder("g-nameless", nil))
        let store = store(server)

        await store.refreshSessionOrganization()

        #expect(store.sessionGroupsAvailable)
        #expect(store.sessionGroups.map(\.name) == ["Kelpi", "Kelpi › Diseño", "Radar"])
        #expect(store.sessionGroupIds == ["s1": "g-radar", "s2": "g-kelpi-design"])
        #expect(store.pinnedSessionIds == ["p1"])
    }

    @Test func withoutFoldersOnTheRelayThereAreNoGroups() async throws {
        let server = OrganizationServer()
        server.foldersEnabled = false
        server.seed(folder: try folder("g-radar", ["name": "Radar"]), assigned: ["s1"])
        let store = store(server)

        await store.refreshSessionOrganization()

        #expect(!store.sessionGroupsAvailable)
        #expect(store.sessionGroups.isEmpty && store.sessionGroupIds.isEmpty)
        #expect(store.pinnedSessionIds == ["p1"])
    }

    @Test func aSessionMovedToANewGroupIsSavedSealedForTheAccount() async throws {
        let server = OrganizationServer()
        let store = store(server)
        await store.refreshSessionOrganization()

        await store.moveToNewGroup("s1", named: "  Radar  ")

        let group = try #require(store.sessionGroups.first)
        #expect(store.sessionGroups.map(\.name) == ["Radar"])
        #expect(store.sessionGroupIds == ["s1": group.id])
        let saved = try #require(server.folder(group.id))
        #expect(saved["folderKey"]?.stringValue == group.id)
        #expect(saved["parentFolderId"]?.isNull == true && saved["parentFolderKey"]?.isNull == true)
        #expect(saved["display"]?["t"]?.stringValue == "encrypted")
        #expect(name(of: saved) == "Radar")
        #expect(server.group(of: "s1") == group.id)
        // Another device reads the same.
        let other = self.store(server)
        await other.refreshSessionOrganization()
        #expect(other.sessionGroups.map(\.name) == ["Radar"] && other.sessionGroupIds == ["s1": group.id])
    }

    @Test func aPlainAccountKeepsGroupNamesPlain() async throws {
        let server = OrganizationServer()
        server.plainAccount = true
        let store = store(server)
        await store.refreshSessionOrganization()

        await store.moveToNewGroup("s1", named: "Radar")

        let group = try #require(store.sessionGroups.first)
        let saved = try #require(server.folder(group.id))
        #expect(saved["display"]?["t"]?.stringValue == "plain")
        #expect(name(of: saved) == "Radar")
    }

    @Test func renamingAGroupKeepsWhatTheWebAppStoredWithIt() async throws {
        let server = OrganizationServer()
        let workspace: JSONValue = ["t": "workspaceScope", "serverId": "srv", "machineId": "m1", "rootPath": "/Users/manny/kelpi"]
        server.seed(folder: try folder("g-kelpi", ["name": "Kelpi", "workspace": workspace], sortKey: "a0"))
        let store = store(server)
        await store.refreshSessionOrganization()

        await store.renameGroup("g-kelpi", to: "Kelpi Web")

        #expect(store.sessionGroups.map(\.name) == ["Kelpi Web"])
        let saved = try #require(server.folder("g-kelpi"))
        let payload = try #require(saved["display"]?["c"]?.stringValue.flatMap { AccountScopedBlob.open($0, kind: .sessionOrganizationDisplay, machineKey: machineKey) })
        #expect(payload["name"]?.stringValue == "Kelpi Web")
        #expect(payload["workspace"] == workspace)
        #expect(saved["sortKey"]?.stringValue == "a0")
    }

    @Test func removingFromAGroupAndDeletingOneLeaveTheSessionsInTheList() async throws {
        let server = OrganizationServer()
        server.seed(folder: try folder("g-radar", ["name": "Radar"]), assigned: ["s1", "s2"])
        let store = store(server)
        await store.refreshSessionOrganization()

        await store.moveToGroup("s1", nil)
        #expect(store.sessionGroupIds == ["s2": "g-radar"])
        #expect(server.group(of: "s1") == nil)

        await store.deleteGroup("g-radar")
        #expect(store.sessionGroups.isEmpty && store.sessionGroupIds.isEmpty)
        #expect(server.folder("g-radar") == nil && server.group(of: "s2") == nil)
    }

    @Test func aGroupTheRelayRefusesIsTakenBack() async throws {
        let server = OrganizationServer()
        server.seed(folder: try folder("g-radar", ["name": "Radar"]))
        let store = store(server)
        await store.refreshSessionOrganization()
        // Deleted on another device since this one last looked.
        server.remove(folder: "g-radar")

        await store.moveToGroup("s1", "g-radar")
        #expect(store.sessionGroupIds.isEmpty)
        #expect(store.lastError != nil)
        // And the list reads the groups again: that one is gone.
        #expect(store.sessionGroups.isEmpty)
    }

    @Test func aListReadWhileAMoveIsSentDoesNotTakeItBack() async throws {
        let server = OrganizationServer()
        server.seed(folder: try folder("g-radar", ["name": "Radar"]))
        let store = store(server)
        await store.refreshSessionOrganization()
        server.holdMoves()

        let move = Task { await store.moveToGroup("s1", "g-radar") }
        while server.heldMoves == 0 { try await Task.sleep(for: .milliseconds(5)) }
        // A session list sync reads the organization before the relay has the move.
        await store.refreshSessionOrganization()
        #expect(store.sessionGroupIds == ["s1": "g-radar"])

        server.release()
        await move.value
        #expect(store.sessionGroupIds == ["s1": "g-radar"])
        #expect(server.group(of: "s1") == "g-radar")
    }

    @Test func aNewGroupStaysWhenOnlyTheMoveIntoItFails() async throws {
        let server = OrganizationServer()
        server.goneSessions = ["gone"]
        let store = store(server)
        await store.refreshSessionOrganization()

        await store.moveToNewGroup("gone", named: "Radar")

        // The relay made the group; only the session stays where it was.
        let group = try #require(store.sessionGroups.first)
        #expect(store.sessionGroups.map(\.name) == ["Radar"])
        #expect(server.folder(group.id) != nil)
        #expect(store.sessionGroupIds.isEmpty)
        #expect(store.lastError != nil)
    }

    @Test func renamingAGroupDeletedOnAnotherDeviceDoesNotBringItBack() async throws {
        let server = OrganizationServer()
        server.seed(folder: try folder("g-radar", ["name": "Radar"]))
        let store = store(server)
        await store.refreshSessionOrganization()
        server.remove(folder: "g-radar")

        await store.renameGroup("g-radar", to: "Radar 2")

        #expect(server.folder("g-radar") == nil)
        #expect(store.sessionGroups.isEmpty)
    }

    // MARK: Order

    private func sortKeys(_ server: OrganizationServer, _ ids: [String]) -> [String?] {
        ids.map { server.folder($0)?["sortKey"]?.stringValue }
    }

    /// Whether the web app's fractional indexing (`fractional-indexing` validateOrderKey) takes the
    /// key: its head letter sets how long the whole-number part is, digits are base 62, and a
    /// fraction doesn't end in 0.
    private static func webReads(_ key: String) -> Bool {
        let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        let characters = Array(key)
        guard let head = characters.first?.asciiValue else { return false }
        let integerLength: Int
        switch head {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): integerLength = Int(head - UInt8(ascii: "a")) + 2
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): integerLength = Int(UInt8(ascii: "Z") - head) + 2
        default: return false
        }
        guard characters.count >= integerLength, characters.dropFirst().allSatisfy(digits.contains) else { return false }
        return characters.count == integerLength || characters.last != "0"
    }

    /// Three groups listed by name (none ordered yet): Alpha, Beta, Gamma.
    private func threeGroups(_ server: OrganizationServer) throws {
        server.seed(folder: try folder("g-a", ["name": "Alpha"]))
        server.seed(folder: try folder("g-b", ["name": "Beta"]))
        server.seed(folder: try folder("g-c", ["name": "Gamma"]))
    }

    @Test func aGroupMovedUpIsListedThereOnEveryDevice() async throws {
        let server = OrganizationServer()
        try threeGroups(server)
        let store = store(server)
        await store.refreshSessionOrganization()
        #expect(store.sessionGroups.map(\.name) == ["Alpha", "Beta", "Gamma"])

        await store.moveGroup("g-c", by: -1)

        #expect(store.sessionGroups.map(\.name) == ["Alpha", "Gamma", "Beta"])
        #expect(sortKeys(server, ["g-a", "g-c", "g-b"]) == ["g0000000", "g0000001", "g0000002"])
        // The web app orders groups around these keys (fractional indexing): each must be one it reads.
        #expect(sortKeys(server, ["g-a", "g-b", "g-c"]).allSatisfy { $0.map(Self.webReads) == true })
        // Each write kept the group's name.
        #expect(["g-a", "g-b", "g-c"].map { name(of: server.folder($0)) } == ["Alpha", "Beta", "Gamma"])
        let other = self.store(server)
        await other.refreshSessionOrganization()
        #expect(other.sessionGroups.map(\.name) == ["Alpha", "Gamma", "Beta"])
    }

    @Test func onlyTheGroupsThatChangePlaceAreWritten() async throws {
        let server = OrganizationServer()
        try threeGroups(server)
        let store = store(server)
        await store.refreshSessionOrganization()
        await store.moveGroup("g-c", by: -1)
        let saves = server.requests.count { $0 == "POST /v2/session-organization/folders" }

        await store.moveGroup("g-a", by: 1)

        #expect(store.sessionGroups.map(\.name) == ["Gamma", "Alpha", "Beta"])
        #expect(server.requests.count { $0 == "POST /v2/session-organization/folders" } == saves + 2)
        // At the ends there's nowhere to go.
        await store.moveGroup("g-c", by: -1)
        await store.moveGroup("g-b", by: 1)
        #expect(server.requests.count { $0 == "POST /v2/session-organization/folders" } == saves + 2)
    }

    @Test func groupsInsideAnotherMoveOnlyAmongThemselves() async throws {
        let server = OrganizationServer()
        server.seed(folder: try folder("g-kelpi", ["name": "Kelpi"]))
        server.seed(folder: try folder("g-kelpi-design", ["name": "Diseño"], parent: "g-kelpi"))
        server.seed(folder: try folder("g-kelpi-web", ["name": "Web"], parent: "g-kelpi"))
        server.seed(folder: try folder("g-radar", ["name": "Radar"]))
        let store = store(server)
        await store.refreshSessionOrganization()
        #expect(store.siblingGroups(of: "g-kelpi-web").map(\.id) == ["g-kelpi-design", "g-kelpi-web"])
        #expect(store.siblingGroups(of: "g-radar").map(\.id) == ["g-kelpi", "g-radar"])

        await store.moveGroup("g-kelpi-web", by: -1)
        await store.moveGroup("g-radar", by: -1)

        #expect(store.sessionGroups.map(\.name) == ["Radar", "Kelpi", "Kelpi › Web", "Kelpi › Diseño"])
    }

    @Test func anOrderTheRelayRefusesIsTakenBack() async throws {
        let server = OrganizationServer()
        try threeGroups(server)
        let store = store(server)
        await store.refreshSessionOrganization()
        server.refusesSaves = true

        await store.moveGroup("g-c", by: -1)

        #expect(store.sessionGroups.map(\.name) == ["Alpha", "Beta", "Gamma"])
        #expect(store.lastError != nil)
    }

    @Test func ordersAskedOneAfterAnotherEndWithTheLast() async throws {
        let server = OrganizationServer()
        try threeGroups(server)
        let store = store(server)
        await store.refreshSessionOrganization()
        server.holdNextSave()

        let first = Task { await store.reorderGroups(["g-c", "g-a", "g-b"]) }
        while server.heldMoves == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let second = Task { await store.reorderGroups(["g-b", "g-c", "g-a"]) }
        try await Task.sleep(for: .milliseconds(50))
        server.release()
        await first.value
        await second.value

        #expect(store.sessionGroups.map(\.name) == ["Beta", "Gamma", "Alpha"])
        let other = self.store(server)
        await other.refreshSessionOrganization()
        #expect(other.sessionGroups.map(\.name) == ["Beta", "Gamma", "Alpha"])
    }

    @Test func aGroupRenamedWhileAnOrderIsSavedKeepsItsNewName() async throws {
        let server = OrganizationServer()
        try threeGroups(server)
        let store = store(server)
        await store.refreshSessionOrganization()
        server.holdNextSave()

        let order = Task { await store.reorderGroups(["g-c", "g-b", "g-a"]) }
        while server.heldMoves == 0 { try await Task.sleep(for: .milliseconds(5)) }
        await store.renameGroup("g-b", to: "Bet")
        server.release()
        await order.value

        #expect(name(of: server.folder("g-b")) == "Bet")
        #expect(store.sessionGroups.map(\.name) == ["Gamma", "Bet", "Alpha"])
        let other = self.store(server)
        await other.refreshSessionOrganization()
        #expect(other.sessionGroups.map(\.name) == ["Gamma", "Bet", "Alpha"])
    }

    @Test func anOrderStopsWhenTheAccountChangesMidway() async throws {
        let server = OrganizationServer()
        try threeGroups(server)
        let store = store(server)
        await store.refreshSessionOrganization()
        server.holdNextSave()

        let order = Task { await store.reorderGroups(["g-c", "g-b", "g-a"]) }
        while server.heldMoves == 0 { try await Task.sleep(for: .milliseconds(5)) }
        // Onto another account (as switching relays does) while the first group is being saved.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OrganizationURLProtocol.self]
        store.installForTesting(api: HappierAPI(server: URL(string: "https://groups.invalid")!, token: "u", session: URLSession(configuration: configuration)),
                                keys: try AccountKeys(masterSecret: Data(repeating: 9, count: 32)),
                                snapshotDirectory: FileManager.default.temporaryDirectory.appending(path: "groups-\(UUID().uuidString)")) { _, _ in [] }
        server.release()
        await order.value

        // None of the first account's groups was sealed with the other account's key.
        #expect(["g-a", "g-b", "g-c"].map { name(of: server.folder($0)) } == ["Alpha", "Beta", "Gamma"])
    }

    @Test func anOrderKeepsAGroupDeletedOnAnotherDeviceDeleted() async throws {
        let server = OrganizationServer()
        try threeGroups(server)
        let store = store(server)
        await store.refreshSessionOrganization()
        server.remove(folder: "g-b")

        await store.reorderGroups(["g-c", "g-b", "g-a"])

        #expect(server.folder("g-b") == nil)
        #expect(store.sessionGroups.map(\.name) == ["Gamma", "Alpha"])
    }

    /// A plain session row; `parent` is the session it was started from.
    private func session(_ id: String, parent: String? = nil) throws -> Session {
        var metadata: [String: JSONValue] = ["name": "t", "path": "/a"]
        if let parent { metadata["spawnedBySessionV1"] = ["parentSessionId": .string(parent)] }
        return try Session(row: ["id": .string(id), "encryptionMode": "plain", "metadata": .string(String(decoding: try JSONValue.object(metadata).encoded(), as: UTF8.self)),
                                 "metadataVersion": 1, "active": true, "updatedAt": 1], keys: nil)
    }

    /// `store`, with the relay taking every metadata write.
    private func nestingStore(_ server: OrganizationServer, sessions: [Session]) -> HappierStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OrganizationURLProtocol.self]
        OrganizationURLProtocol.server = server
        let api = HappierAPI(server: URL(string: "https://groups.invalid")!, token: "t", session: URLSession(configuration: configuration))
        let store = HappierStore(server: URL(string: "https://groups.invalid")!)
        store.installForTesting(api: api, keys: keys, snapshotDirectory: FileManager.default.temporaryDirectory.appending(path: "groups-\(UUID().uuidString)")) { event, payload in
            guard event == "update-metadata" else { return [] }
            return [["result": "success", "version": 2, "metadata": payload["metadata"] ?? .null]]
        }
        for session in sessions { store.sessions[session.id] = session }
        return store
    }

    @Test func aSessionPutInsideAnotherGoesWithIt() async throws {
        let server = OrganizationServer()
        server.seed(folder: try folder("g-radar", ["name": "Radar"]), assigned: ["s1"])
        let store = nestingStore(server, sessions: [try session("p"), try session("s1")])
        await store.refreshSessionOrganization()

        await store.nest("s1", under: "p")

        // Listed under "p" now, outside the group.
        #expect(store.sessions["s1"]?.parentSessionId == "p")
        #expect(store.sessionGroupIds.isEmpty)
        #expect(server.group(of: "s1") == nil)
    }

    @Test func aSessionPutInsideAnotherOfItsGroupFollowsItFromThen() async throws {
        let server = OrganizationServer()
        server.seed(folder: try folder("g-radar", ["name": "Radar"]), assigned: ["p", "s1"])
        let store = nestingStore(server, sessions: [try session("p"), try session("s1")])
        await store.refreshSessionOrganization()

        await store.nest("s1", under: "p")

        // Still in Radar through "p", and out of it when "p" leaves.
        #expect(store.sessionGroupIds == ["p": "g-radar"])
        #expect(store.groupId(of: "s1") == "g-radar")
        #expect(server.group(of: "s1") == nil)
    }

    @Test func aSubSessionOfAnArchivedSessionIsNotInItsGroup() async throws {
        let server = OrganizationServer()
        // "p" was archived: the relay keeps its group, the list no longer has it.
        server.seed(folder: try folder("g-radar", ["name": "Radar"]), assigned: ["p"])
        let store = nestingStore(server, sessions: [try session("c", parent: "p")])
        await store.refreshSessionOrganization()

        #expect(store.groupId(of: "c") == nil)
        #expect(!store.isGroupedOnItsOwn("c"))
    }

    @Test func aSessionTakenOutOfAnotherStaysInTheGroupItWasListedIn() async throws {
        let server = OrganizationServer()
        server.seed(folder: try folder("g-radar", ["name": "Radar"]), assigned: ["p"])
        let store = nestingStore(server, sessions: [try session("p"), try session("c", parent: "p")])
        await store.refreshSessionOrganization()
        // Listed in the group under "p", without a group of its own.
        #expect(store.groupId(of: "c") == "g-radar")
        #expect(!store.isGroupedOnItsOwn("c"))

        await store.nest("c", under: nil)

        #expect(store.sessions["c"]?.parentSessionId == nil)
        #expect(store.sessionGroupIds["c"] == "g-radar")
        #expect(server.group(of: "c") == "g-radar")
        #expect(store.isGroupedOnItsOwn("c"))
    }
}

/// Where grouped sessions show in the list, and the list by folder.
@Suite struct SessionGroupSidebarTests {
    private func session(_ id: String, active: Bool = false, at: Double, parent: String? = nil, path: String? = "/a",
                         machine: String = "m1", host: String = "mac") throws -> Session {
        var metadata: [String: JSONValue] = ["name": "t", "machineId": .string(machine), "host": .string(host)]
        if let path { metadata["path"] = .string(path) }
        if let parent { metadata["spawnedBySessionV1"] = ["parentSessionId": .string(parent)] }
        return try Session(row: ["id": .string(id), "encryptionMode": "plain", "metadata": .string(String(decoding: try JSONValue.object(metadata).encoded(), as: UTF8.self)),
                                 "metadataVersion": 1, "active": .bool(active), "updatedAt": .number(at)], keys: nil)
    }

    private func ids(_ nodes: [SessionTreeNode<Session>]) -> [String] {
        nodes.map { node in
            guard let children = node.children else { return node.id }
            return "\(node.id)(\(ids(children).joined(separator: ",")))"
        }
    }

    private func group(_ id: String, _ name: String) -> SessionGroup {
        SessionGroup(id: id, name: name)
    }

    @Test func groupedSessionsShowInTheirGroupWhateverTheirState() throws {
        let sessions = [
            try session("run", active: true, at: 30),
            try session("radarRun", active: true, at: 40),
            try session("radarOld", at: 5),
            try session("radarChild", active: true, at: 50, parent: "radarOld"),
            try session("pinnedRadar", at: 60),
            try session("elsewhere", active: true, at: 45, parent: "radarRun"),
        ]
        let groups = SessionSidebar.groups(sessions, pinned: ["pinnedRadar"],
                                           groups: [group("g-radar", "Radar"), group("g-empty", "Empty"), group("g-kelpi", "Kelpi")],
                                           groupIds: ["radarRun": "g-radar", "radarOld": "g-radar", "pinnedRadar": "g-radar", "elsewhere": "g-kelpi"])
        // Pinned wins over the group; a sub-session goes with its parent unless put in another group.
        #expect(ids(groups.pinned) == ["pinnedRadar"])
        #expect(groups.grouped.map(\.group.id) == ["g-radar", "g-empty", "g-kelpi"])
        #expect(ids(groups.grouped[0].nodes) == ["radarOld(radarChild)", "radarRun"])
        #expect(groups.grouped.map(\.pinned) == [1, 0, 0])
        #expect(groups.grouped[1].nodes.isEmpty)
        #expect(ids(groups.grouped[2].nodes) == ["elsewhere"])
        #expect(ids(groups.active) == ["run"])
        #expect(groups.stopped.isEmpty && groups.resting.isEmpty)
    }

    @Test func aSubSessionPutInTheGroupItIsListedInKeepsItsPlace() throws {
        let sessions = [
            try session("top", at: 10),
            try session("middle", at: 20, parent: "top"),
            try session("bottom", at: 30, parent: "middle"),
            try session("pinned", at: 40),
            try session("underPinned", at: 50, parent: "pinned"),
        ]
        // "bottom" is in Radar as "middle" is, through "top"; "underPinned" is, but "pinned" is in Pinned.
        let groups = SessionSidebar.groups(sessions, pinned: ["pinned"], groups: [group("g-radar", "Radar")],
                                           groupIds: ["top": "g-radar", "bottom": "g-radar", "underPinned": "g-radar"])
        #expect(ids(groups.grouped[0].nodes) == ["underPinned", "top(middle(bottom))"])
        #expect(ids(groups.pinned) == ["pinned"])
    }

    @Test func aSubSessionOfASessionNotListedGoesByItsOwnGroup() throws {
        // "gone" (archived, in Radar) isn't listed: "orphan" is a top row, "grandchild" in Radar.
        let sessions = [try session("orphan", active: true, at: 10, parent: "gone"),
                        try session("grandchild", active: true, at: 20, parent: "orphan")]
        let groups = SessionSidebar.groups(sessions, pinned: [], groups: [group("g-radar", "Radar")],
                                           groupIds: ["gone": "g-radar", "grandchild": "g-radar"])
        #expect(ids(groups.grouped[0].nodes) == ["grandchild"])
        #expect(ids(groups.active) == ["orphan"])
    }

    @Test func aSessionInAGroupNoLongerListedIsInTheList() throws {
        // Its group was deleted on another device: it is back with the others.
        let groups = SessionSidebar.groups([try session("s1", active: true, at: 1)], pinned: [], groups: [], groupIds: ["s1": "g-gone"])
        #expect(groups.grouped.isEmpty)
        #expect(ids(groups.active) == ["s1"])
    }

    @Test func byFolderSessionsGoUnderTheFolderTheyWorkIn() throws {
        let sessions = [
            try session("happier1", active: true, at: 10, path: "/Users/manny/Projects/happier"),
            try session("home", active: true, at: 30, path: "/Users/manny"),
            try session("happier2", at: 20, path: "/Users/manny/Projects/happier/"),
            try session("child", active: true, at: 40, parent: "happier2", path: "/tmp/elsewhere"),
            try session("nowhere", at: 5, path: nil),
        ]
        let groups = SessionSidebar.groups(sessions, pinned: [])
        let folders = SessionSidebar.folders(groups.active + groups.recent + groups.stopped)
        // Newest activity first; a sub-session stays with its parent's folder.
        #expect(folders.map(\.title) == ["happier", "manny", "No Folder"])
        #expect(ids(folders[0].nodes) == ["happier2(child)", "happier1"])
        #expect(ids(folders[1].nodes) == ["home"])
        #expect(ids(folders[2].nodes) == ["nowhere"])
    }

    @Test func foldersWithTheSameNameAreToldApart() throws {
        let sessions = [
            try session("work", active: true, at: 30, path: "/Users/manny/work/api"),
            try session("side", active: true, at: 20, path: "/Users/manny/side/api"),
            try session("mini", active: true, at: 10, path: "/Users/manny/work/api", machine: "m2", host: "mini"),
        ]
        let folders = SessionSidebar.folders(sessions)
        #expect(folders.map(\.title) == ["/Users/manny/work/api · mac", "/Users/manny/side/api", "/Users/manny/work/api · mini"])
    }
}

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
                guard let json = try? JSONValue.parse(body), let id = json["folderId"]?.stringValue else { return (400, ["error": "invalid-params"]) }
                var folder = json.objectValue ?? [:]
                folder["archivedAt"] = .null
                folder["createdAt"] = 1
                folder["updatedAt"] = 1
                folders[id] = .object(folder)
                return (200, ["folder": .object(folder)])
            case ("PUT", _) where path.hasPrefix("/v2/session-organization/folder-assignments/"):
                let sessionId = String(path.dropFirst("/v2/session-organization/folder-assignments/".count))
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
        #expect(groups.grouped[1].nodes.isEmpty)
        #expect(ids(groups.grouped[2].nodes) == ["elsewhere"])
        #expect(ids(groups.active) == ["run"])
        #expect(groups.stopped.isEmpty && groups.resting.isEmpty)
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

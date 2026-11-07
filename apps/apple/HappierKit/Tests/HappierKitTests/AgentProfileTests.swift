import Foundation
import Testing
@testable import HappierKit

/// User-defined agents (`packages/protocol/src/agentProfiles/*`): sealed profiles in the account's
/// UserKVStore (`/v1/kv`), the identity a spawn carries and the one a session's metadata shows.
@Suite struct AgentProfileTests {
    static let machineKey = Data(0..<32)

    /// `sealAccountScopedBlobCiphertext({kind:'agent_profile', material:{type:'dataKey', machineKey:0..31},
    /// payload:{v:1,id:'a1',name:'Mateo'}})` with a nonce of 3s.
    static let tsSealed = "oQsDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwNfxTIszPpD41nXf3KS0/lZgvn5PC3jsfXk6G/iDvumOpH1WhRPJfbom3EmUy7UgCM="

    static func julian() -> AgentProfile {
        AgentProfile(id: "0f1e", name: "Julián", emoji: "🤖", description: "Arquitecto de Happier.", providerId: "claude",
                     modelId: "claude-opus-5-5", effort: "medium",
                     account: .init(label: "Claude DevManny", configDir: "~/.claude-julian"), updatedAt: 1000)
    }

    @Test func opensWhatTheTypeScriptClientSeals() throws {
        let opened = try #require(AccountScopedBlob.open(Self.tsSealed, kind: .agentProfile, machineKey: Self.machineKey))
        #expect(opened == ["v": 1, "id": "a1", "name": "Mateo"])
        #expect(AccountScopedBlob.open(Self.tsSealed, kind: .agentPresence, machineKey: Self.machineKey) == nil)
    }

    @Test func profilesRoundTripThroughTheirSealedValue() throws {
        let profile = Self.julian()
        let sealed = try profile.sealed(machineKey: Self.machineKey)
        #expect(Base64.decode(sealed)?.prefix(2) == Data([0xA1, 11]))
        #expect(AgentProfile.open(sealed, machineKey: Self.machineKey) == profile)
        #expect(AgentProfile.open(sealed, machineKey: Data(repeating: 9, count: 32)) == nil)
    }

    @Test func keysAreOpaqueAndOnlyProfileKeysAreProfiles() {
        // Profiles have their own prefix, so an agent's memory can't crowd them out of a listing.
        #expect(AgentProfile.kvKey(id: "0F1E") == "agentprofile/0f1e")
        #expect(AgentProfile.id(fromKey: "agentprofile/0f1e") == "0f1e")
        // Where builds before the move kept them.
        #expect(AgentProfile.legacyKvKey(id: "0F1E") == "agent/0f1e/profile")
        #expect(AgentProfile.id(fromKey: "agent/0f1e/profile") == "0f1e")
        #expect(AgentProfile.id(fromKey: "agent/0f1e/now/s1") == nil)
        #expect(AgentProfile.id(fromKey: "presence/s1") == nil)
    }

    @Test func reconcilingCopiesProfilesOnlyOldBuildsKnowAndKeepsTheNewestOfEach() throws {
        var older = Self.julian(); older.updatedAt = 10
        var newer = Self.julian(); newer.name = "Julián 2"; newer.updatedAt = 20
        var tomas = Self.julian(); tomas = AgentProfile(id: "70", name: "Tomás", providerId: "claude", account: .init(label: "Nómada"), updatedAt: 5)

        // Only an old build knows Tomás: copy it to the new key (create, version -1).
        // Julián: an old build edited it after the move (legacy newer): copy over the new key's version.
        let plan = AgentProfile.reconcile(current: [.init(profile: older, version: 4)],
                                          legacy: [.init(profile: newer, version: 1), .init(profile: tomas, version: 0)])
        #expect(plan.profiles.map(\.name).sorted() == ["Julián 2", "Tomás"])
        #expect(plan.copies.map { [$0.profile.id, String($0.version)] }.sorted { $0[0] < $1[0] } == [[older.id, "4"], ["70", "-1"]])

        // Already moved and not edited by an old build since: nothing to copy.
        let settled = AgentProfile.reconcile(current: [.init(profile: newer, version: 5)], legacy: [.init(profile: older, version: 1)])
        #expect(settled.copies.isEmpty)
        #expect(settled.profiles.map(\.name) == ["Julián 2"])
    }

    @Test func listingKeepsLiveProfilesAndSkipsDeletedOrForeignRows() throws {
        let sealed = try Self.julian().sealed(machineKey: Self.machineKey)
        let items: JSONValue = ["items": [
            ["key": "agent/0f1e/profile", "value": .string(sealed), "version": 3],
            ["key": "agent/dead/profile", "value": "", "version": 5],
            ["key": "agent/0f1e/journal/1", "value": .string(sealed), "version": 0],
            ["key": "agent/bad/profile", "value": "bm90IHNlYWxlZA==", "version": 1],
        ]]
        let records = AgentProfile.records(fromList: items, machineKey: Self.machineKey)
        #expect(records.map(\.profile.id) == ["0f1e"])
        #expect(records.first?.version == 3)
    }

    @Test func spawnCarriesTheIdentityAndClaudesConfigFolder() {
        let params = SpawnRequest.params(directory: "/p", agentId: "claude", permissionMode: .yolo, nonce: "n",
                                         approveNewDirectory: false, agent: Self.julian(), now: 5)
        #expect(params["agentIdentityV1"] == ["v": 1, "id": "0f1e", "name": "Julián", "emoji": "🤖", "description": "Arquitecto de Happier."])
        #expect(params["environmentVariables"] == ["CLAUDE_CONFIG_DIR": "~/.claude-julian"])
    }

    @Test func codexAgentsUseTheMachinesOwnLogin() {
        var mateo = Self.julian()
        mateo.providerId = "codex"
        let params = SpawnRequest.params(directory: "/p", agentId: "codex", permissionMode: .yolo, nonce: "n",
                                         approveNewDirectory: false, agent: mateo, now: 5)
        #expect(params["agentIdentityV1"]?["name"] == "Julián")
        #expect(params["environmentVariables"] == nil)
        let none = SpawnRequest.params(directory: "/p", agentId: "claude", permissionMode: .yolo, nonce: "n", approveNewDirectory: false, now: 5)
        #expect(none["agentIdentityV1"] == nil)
    }

    @Test func aSessionShowsTheAgentItRunsAs() throws {
        func session(_ metadata: [String: JSONValue]) throws -> Session {
            let row: [String: JSONValue] = [
                "id": "s1", "seq": 1, "createdAt": 1, "updatedAt": 2, "active": false, "encryptionMode": "plain",
                "metadata": .string(String(decoding: try JSONValue.object(metadata).encoded(), as: UTF8.self)), "metadataVersion": 1,
            ]
            return try Session(row: .object(row), keys: nil)
        }
        let withAgent = try session(["path": "/p", "agentIdentityV1": ["v": 1, "id": "0f1e", "name": "Julián", "emoji": "🤖"]])
        #expect(withAgent.agentIdentity == AgentIdentity(id: "0f1e", name: "Julián", emoji: "🤖"))
        #expect(withAgent.agentIdentity?.label == "🤖 Julián")
        #expect(try session(["path": "/p"]).agentIdentity == nil)
        #expect(try session(["agentIdentityV1": ["v": 1, "id": "x", "name": "  "]]).agentIdentity == nil)
    }
}

/// HTTP is the mocked boundary; the request building and response parsing stay real.
private final class KVURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responder: ((URLRequest, Data) -> (Int, String))?

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
        let (status, text) = Self.responder?(request, body) ?? (500, "{}")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct AgentProfileKVTests {
    private func api() -> (HappierAPI, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KVURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return (HappierAPI(server: URL(string: "https://kv.invalid")!, token: "t", session: session), session)
    }

    @Test func listsByPrefix() async throws {
        KVURLProtocol.responder = { request, _ in
            #expect(request.url?.path == "/v1/kv")
            #expect(request.httpMethod == "GET")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.contains(URLQueryItem(name: "prefix", value: "agent/")))
            return (200, #"{"items":[{"key":"agent/a/profile","value":"x","version":2}]}"#)
        }
        let (api, session) = api()
        defer { session.invalidateAndCancel() }
        let listed = try await api.kvList(prefix: "agent/")
        #expect(listed["items"]?[0]?["version"] == 2)
    }

    @Test func savesWithTheVersionAndReportsAConflictWithTheCurrentRow() async throws {
        KVURLProtocol.responder = { request, body in
            #expect(request.httpMethod == "POST")
            #expect((try? JSONValue.parse(body)) == ["mutations": [["key": "agent/a/profile", "value": "c", "version": -1]]])
            return (200, #"{"success":true,"results":[{"key":"agent/a/profile","version":0}]}"#)
        }
        let (api, session) = api()
        defer { session.invalidateAndCancel() }
        #expect(try await api.kvWrite(key: "agent/a/profile", value: "c", version: -1) == .saved(version: 0))

        KVURLProtocol.responder = { _, _ in
            (409, #"{"success":false,"errors":[{"key":"agent/a/profile","error":"version-mismatch","version":4,"value":"cur"}]}"#)
        }
        #expect(try await api.kvWrite(key: "agent/a/profile", value: nil, version: 1) == .conflict(version: 4, value: "cur"))
    }
}

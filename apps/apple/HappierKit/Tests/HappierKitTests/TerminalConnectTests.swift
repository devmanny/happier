import Foundation
import Testing
@testable import HappierKit

// Approving a computer's `happier auth login` from this device, against the web app's
// implementation (`apps/ui/sources/hooks/session/useConnectTerminal.ts`, `auth/flows/approve.ts`).
//
// Golden vectors produced by `packages/protocol/src/crypto/terminalProvisioningV2.ts` with: terminal
// secret key 32×0x09, pairing secret 32×0x0b, created 1000, expires 61000, content key 32×0x07 and
// the counting random source (1, 2, 3, ...). The V3 one is the vector pinned in
// `terminalProvisioningV2.test.ts`; the link is `buildTerminalConnectLinks` in
// `packages/cli-common/src/links/index.ts` for relay `https://relay.example.com:8443/`.

private func hex(_ s: String) -> Data {
    var data = Data()
    var index = s.startIndex
    while index < s.endIndex {
        let next = s.index(index, offsetBy: 2)
        data.append(UInt8(s[index..<next], radix: 16)!)
        index = next
    }
    return data
}

private func repeated(_ byte: UInt8, _ count: Int = 32) -> Data { Data(repeating: byte, count: count) }

private final class CountingRandom: @unchecked Sendable {
    var next: UInt8 = 1
    func bytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in defer { next &+= 1 }; return next })
    }
}

private enum Vectors {
    static let terminalPublicKey = hex("57db4b359f23ae5e146e4e2512056704722506348c150c14753d0c933d04d421")
    static let terminalSecretKey = repeated(0x09)
    static let pairing = TerminalConnectLink.Pairing(secret: "CwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCws", createdAtMs: 1000, expiresAtMs: 61000)
    static let v3 = hex("4850563307a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c2122232425262728292a2b2c2d2e2f303132333435363738038421ac68edc7135402995448e77117e81672a45e7c6cf4c2adccbbc9002707396eee6a007127b87017ea460009127322e1d42c22f204cd76284a35fc425cc84ccd5c295c34fde4f0e5316eab47e18ea8")
    static let v3TokenOnly = hex("4850563307a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c2122232425262728292a2b2c2d2e2f3031323334353637386b9e8156e67a23cd992b9032808b6eaae9a0b4c19e5d25a47dc2dcbd80731b9080a924b569085af6f2a3ca56969e881980")
    static let v2 = hex("07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c2122232425262728292a2b2c2d2e2f303132333435363738038421ac68edc7135402995448e77117e81672a45e7c6cf4c2adccbbc9002707396eee6a007127b87017ea460009127322")
    static let v2TokenOnly = hex("07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c2122232425262728292a2b2c2d2e2f3031323334353637386b9e8156e67a23cd992b9032808b6eaae9")
    static let mobileLink = "happier://terminal?key=V9tLNZ8jrl4Ubk4lEgVnBHIlBjSMFQwUdT0Mkz0E1CE&server=https%3A%2F%2Frelay.example.com%3A8443&pairingSecret=CwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCws&createdAt=1000&expiresAt=61000"
    static let webLink = "https://happier.nomada.cloud/terminal/connect#key=V9tLNZ8jrl4Ubk4lEgVnBHIlBjSMFQwUdT0Mkz0E1CE&server=https%3A%2F%2Frelay.example.com%3A8443&pairingSecret=CwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCws&createdAt=1000&expiresAt=61000"
    static let key = "V9tLNZ8jrl4Ubk4lEgVnBHIlBjSMFQwUdT0Mkz0E1CE"
    /// A data-key account whose content private key is 32×0x07, so its responses equal the vectors.
    static let dataKey = Credentials.dataKey(token: token, content: ContentKeyPair(publicKey: repeated(0x01), secretKey: repeated(0x07)))
    static let token = "h.\(Base64.urlEncoded(Data(#"{"sub":"acc-1"}"#.utf8))).s"
}

@Suite struct TerminalProvisioningVectorTests {
    @Test func sealsV3LikeTheProtocolPackage() throws {
        let payload = try TerminalProvisioning.sealV3(contentPrivateKey: repeated(0x07), recipient: Vectors.terminalPublicKey,
                                                      pairing: Vectors.pairing, random: CountingRandom().bytes)
        #expect(payload == Vectors.v3)
    }

    @Test func sealsV3TokenOnlyLikeTheProtocolPackage() throws {
        let payload = try TerminalProvisioning.sealV3TokenOnly(recipient: Vectors.terminalPublicKey, pairing: Vectors.pairing, random: CountingRandom().bytes)
        #expect(payload == Vectors.v3TokenOnly)
    }

    @Test func sealsV2AndV2TokenOnlyLikeTheProtocolPackage() throws {
        #expect(try TerminalProvisioning.sealV2(contentPrivateKey: repeated(0x07), recipient: Vectors.terminalPublicKey,
                                                random: CountingRandom().bytes) == Vectors.v2)
        #expect(try TerminalProvisioning.sealV2TokenOnly(recipient: Vectors.terminalPublicKey, random: CountingRandom().bytes) == Vectors.v2TokenOnly)
        // The terminal opens it to the version byte and the content key.
        #expect(HappierCrypto.openBoxBundle(Vectors.v2, secretKey: Vectors.terminalSecretKey) == Data([0]) + repeated(0x07))
    }

    @Test func refusesWhatTheProtocolPackageRefuses() {
        let short = TerminalConnectLink.Pairing(secret: "CwsL", createdAtMs: 1000, expiresAtMs: 61000)
        #expect(throws: (any Error).self) {
            try TerminalProvisioning.sealV3(contentPrivateKey: repeated(0x07), recipient: Vectors.terminalPublicKey, pairing: short, random: CountingRandom().bytes)
        }
        #expect(throws: (any Error).self) {
            try TerminalProvisioning.sealV3TokenOnly(recipient: repeated(0x01, 31), pairing: Vectors.pairing, random: CountingRandom().bytes)
        }
        #expect(throws: (any Error).self) {
            try TerminalProvisioning.sealV2(contentPrivateKey: repeated(0x07, 31), recipient: Vectors.terminalPublicKey, random: CountingRandom().bytes)
        }
    }
}

@Suite struct TerminalConnectLinkTests {
    @Test(arguments: [Vectors.mobileLink, Vectors.webLink, "happier-native://terminal?" + Vectors.mobileLink.split(separator: "?")[1],
                      "happier:///terminal?" + Vectors.mobileLink.split(separator: "?")[1],
                      "  " + Vectors.mobileLink + "\n"])
    func readsTheLinksTheCLIPrints(_ text: String) throws {
        let link = try #require(TerminalConnectLink(text))
        #expect(link.publicKey == Vectors.terminalPublicKey)
        #expect(link.server == URL(string: "https://relay.example.com:8443"))
        #expect(link.pairing == Vectors.pairing)
        #expect(link.expiresAt == Date(timeIntervalSince1970: 61))
    }

    @Test func readsTheLegacyBareKeyAndTheQueryFormOfTheWebLink() throws {
        let legacy = try #require(TerminalConnectLink("happier://terminal?\(Vectors.key)"))
        #expect(legacy.publicKey == Vectors.terminalPublicKey && legacy.server == nil && legacy.pairing == nil)

        // Without a fragment the web route reads the query; with both, the fragment wins.
        let query = try #require(TerminalConnectLink("https://app.example/terminal/connect/?key=\(Vectors.key)&server=https%3A%2F%2FRelay.Example.com%3A443%2F"))
        // The relay as the link spells it (`ServerAddress`); `RelayList.canonical` says which relay it is.
        #expect(query.server == URL(string: "https://Relay.Example.com:443") && query.pairing == nil)
        #expect(query.server.map(RelayList.canonical) == "https://relay.example.com")
        let both = try #require(TerminalConnectLink("https://app.example/terminal/connect?key=AAAA#key=\(Vectors.key)"))
        #expect(both.publicKey == Vectors.terminalPublicKey && both.server == nil)
    }

    @Test(arguments: [
        "createdAt=61000&expiresAt=1000",      // window ends before it starts
        "createdAt=-1&expiresAt=61000",        // before the epoch
        "createdAt=1000.5&expiresAt=61000",    // not an integer
        "createdAt=1000&expiresAt=9007199254740993", // beyond Number.MAX_SAFE_INTEGER
        "createdAt=1000",                      // no end
    ]) func dropsAnInvalidPairingAndKeepsTheLink(_ window: String) throws {
        let link = try #require(TerminalConnectLink("happier://terminal?key=\(Vectors.key)&pairingSecret=abc&\(window)"))
        #expect(link.pairing == nil)
        let noSecret = try #require(TerminalConnectLink("happier://terminal?key=\(Vectors.key)&pairingSecret=%20&createdAt=1&expiresAt=2"))
        #expect(noSecret.pairing == nil)
    }

    @Test func keepsAPairingWhoseStartIsMissingAsTheWebAppDoes() throws {
        // `Number(null)` is 0 in the web parser, a valid start.
        let link = try #require(TerminalConnectLink("happier://terminal?key=\(Vectors.key)&pairingSecret=abc&expiresAt=5"))
        #expect(link.pairing == .init(secret: "abc", createdAtMs: 0, expiresAtMs: 5))
    }

    @Test(arguments: ["javascript:alert(1)", "file:///etc/hosts", "not a url", ""])
    func dropsARelayThatIsNotHTTP(_ server: String) throws {
        let encoded = server.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let link = try #require(TerminalConnectLink("happier://terminal?key=\(Vectors.key)&server=\(encoded)"))
        #expect(link.server == nil)
    }

    @Test(arguments: [
        "happier:///account?\(Vectors.key)",
        "happier://terminal",
        "happier://terminal?server=https%3A%2F%2Frelay.example.com",
        "happier://terminal?key=AAAA",
        "https://app.example/terminal?key=\(Vectors.key)",
        "https://app.example/terminal/connect",
        "ftp://app.example/terminal/connect#key=\(Vectors.key)",
        "other://terminal?key=\(Vectors.key)",
    ]) func rejectsWhatIsNotAComputerLink(_ text: String) {
        #expect(TerminalConnectLink(text) == nil)
    }
}

@Suite struct TerminalConnectPayloadTests {
    private let link = TerminalConnectLink(Vectors.mobileLink)!
    private let unpaired = TerminalConnectLink("happier://terminal?key=\(Vectors.key)")!

    private func status(v2: Bool = true, tokenOnly: Bool = true) -> TerminalConnect.RequestStatus {
        .init(state: .pending, supportsV2: v2, supportsTokenOnly: tokenOnly)
    }

    @Test func aKeyedAccountSealsItsContentKeyAuthenticatedWhenTheLinkIsPaired() throws {
        #expect(try TerminalConnect.response(status: status(), credentials: Vectors.dataKey, link: link, random: CountingRandom().bytes) == Vectors.v3)
        #expect(try TerminalConnect.response(status: status(tokenOnly: false), credentials: Vectors.dataKey, link: unpaired,
                                             random: CountingRandom().bytes) == Vectors.v2)
    }

    @Test func aLegacyAccountSealsTheKeyDerivedFromItsSecret() throws {
        let legacy = Credentials.legacy(token: Vectors.token, secret: Data(0..<32))
        let payload = try TerminalConnect.response(status: status(), credentials: legacy, link: unpaired, random: CountingRandom().bytes)
        // `deriveAccountMachineKeyFromRecoverySecret(0..31)` in `packages/protocol`.
        #expect(HappierCrypto.openBoxBundle(payload, secretKey: Vectors.terminalSecretKey)
                == Data([0]) + hex("56f43aee0c93b2163b5e45b14264d06b0c9613195e23da0190f6838d6ac9c562"))
    }

    @Test func aTokenOnlyAccountAnswersOnlyTerminalsThatAcceptIt() throws {
        let tokenOnly = Credentials.tokenOnly(token: Vectors.token)
        #expect(try TerminalConnect.response(status: status(), credentials: tokenOnly, link: link, random: CountingRandom().bytes) == Vectors.v3TokenOnly)
        #expect(try TerminalConnect.response(status: status(), credentials: tokenOnly, link: unpaired, random: CountingRandom().bytes) == Vectors.v2TokenOnly)
        #expect(throws: TerminalConnect.Unsupported.self) {
            try TerminalConnect.response(status: status(tokenOnly: false), credentials: tokenOnly, link: link, random: CountingRandom().bytes)
        }
    }

    @Test func aTerminalWithoutV2GetsNothing() {
        // The web app's V1 answer (the bare recovery secret) is off by default and not offered here.
        #expect(throws: TerminalConnect.Unsupported.self) {
            try TerminalConnect.response(status: status(v2: false), credentials: Vectors.dataKey, link: link, random: CountingRandom().bytes)
        }
    }
}

// MARK: - Approval over HTTP

/// The relay, simulated at the HTTP boundary; the client's request building and parsing stay real.
private final class TerminalRelay: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable { let method: String; let url: URL; let authorization: String?; let body: JSONValue? }
    nonisolated(unsafe) static var routes: [String: (Int, JSONValue)] = [:]
    nonisolated(unsafe) static var seen: [Seen] = []

    static func reset(_ routes: [String: (Int, JSONValue)]) {
        self.routes = routes
        seen = []
    }

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
        let method = request.httpMethod ?? "GET"
        Self.seen.append(Seen(method: method, url: request.url!, authorization: request.value(forHTTPHeaderField: "Authorization"),
                              body: body.isEmpty ? nil : try? JSONValue.parse(body)))
        let (status, json) = Self.routes["\(method) \(request.url!.path)"] ?? (500, ["error": "not simulated"])
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? json.encoded()) ?? Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct TerminalConnectApprovalTests {
    private let link = TerminalConnectLink(Vectors.mobileLink)!

    private func api() -> HappierAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TerminalRelay.self]
        return HappierAPI(server: URL(string: "https://relay.example.com:8443")!, token: Vectors.token, session: URLSession(configuration: configuration))
    }

    private static func status(_ state: String) -> (Int, JSONValue) {
        (200, ["status": .string(state), "supportsV2": true, "supportsTokenOnly": true])
    }

    private static let plain: (Int, JSONValue) = (200, ["mode": "plain"])

    @Test func approvesAPendingRequestWithTheWebAppsWireShape() async throws {
        TerminalRelay.reset(["GET /v1/account/encryption": Self.plain, "GET /v1/auth/request/status": Self.status("pending"),
                             "POST /v1/auth/response": (200, ["success": true])])

        let outcome = try await TerminalConnect.approve(link, api: api(), credentials: Vectors.dataKey, random: CountingRandom().bytes)

        #expect(outcome == .approved)
        let seen = TerminalRelay.seen
        #expect(seen.map { "\($0.method) \($0.url.path)" } == ["GET /v1/account/encryption", "GET /v1/auth/request/status", "POST /v1/auth/response"])
        // The status is asked without the account's token, the key in standard base64.
        let statusQuery = try #require(URLComponents(url: seen[1].url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(statusQuery == [URLQueryItem(name: "publicKey", value: Vectors.terminalPublicKey.base64EncodedString())])
        #expect(seen[1].authorization == nil)
        #expect(seen[2].authorization == "Bearer \(Vectors.token)")
        #expect(seen[2].body == ["publicKey": .string(Vectors.terminalPublicKey.base64EncodedString()),
                                 "response": .string(Vectors.v3.base64EncodedString())])
    }

    @Test func aRequestAlreadyAnsweredOrGoneIsNotAnsweredAgain() async throws {
        TerminalRelay.reset(["GET /v1/account/encryption": Self.plain, "GET /v1/auth/request/status": Self.status("authorized")])
        #expect(try await TerminalConnect.approve(link, api: api(), credentials: Vectors.dataKey) == .alreadyUsed)
        #expect(!TerminalRelay.seen.contains { $0.method == "POST" })

        TerminalRelay.reset(["GET /v1/account/encryption": Self.plain, "GET /v1/auth/request/status": Self.status("not_found")])
        #expect(try await TerminalConnect.approve(link, api: api(), credentials: Vectors.dataKey) == .expired)
        #expect(!TerminalRelay.seen.contains { $0.method == "POST" })
    }

    @Test func aRequestThatExpiresBeforeTheAnswerIsExpired() async throws {
        TerminalRelay.reset(["GET /v1/account/encryption": Self.plain, "GET /v1/auth/request/status": Self.status("pending"),
                             "POST /v1/auth/response": (404, ["error": "Request not found"])])
        #expect(try await TerminalConnect.approve(link, api: api(), credentials: Vectors.dataKey) == .expired)
    }

    @Test func anEncryptedAccountHandsOutOnlyItsCurrentKey() async throws {
        let legacy = Credentials.legacy(token: Vectors.token, secret: Data(0..<32))
        let signing = "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"
        TerminalRelay.reset(["GET /v1/account/encryption": (200, ["mode": "e2ee"]),
                             "GET /v1/user/acc-1": (200, ["user": ["id": "acc-1", "publicKey": .string(signing)]]),
                             "GET /v1/auth/request/status": Self.status("pending"), "POST /v1/auth/response": (200, ["success": true])])
        #expect(try await TerminalConnect.approve(link, api: api(), credentials: legacy) == .approved)

        // The relay says the Account's key is another one: nothing leaves this device.
        TerminalRelay.reset(["GET /v1/account/encryption": (200, ["mode": "e2ee"]),
                             "GET /v1/user/acc-1": (200, ["user": ["id": "acc-1", "publicKey": .string(String(repeating: "ab", count: 32))]]),
                             "GET /v1/auth/request/status": Self.status("pending"), "POST /v1/auth/response": (200, ["success": true])])
        await #expect(throws: AccountKeyProvisioning.Unavailable.self) {
            try await TerminalConnect.approve(link, api: api(), credentials: legacy)
        }
        #expect(TerminalRelay.seen.map(\.url.path) == ["/v1/account/encryption", "/v1/user/acc-1"])
    }

    @Test func aTokenOnlyAccountOfAnEncryptedRelayCannotApprove() async throws {
        TerminalRelay.reset(["GET /v1/account/encryption": (200, ["mode": "e2ee"]),
                             "GET /v1/user/acc-1": (200, ["user": ["id": "acc-1", "publicKey": "00"]]),
                             "GET /v1/auth/request/status": Self.status("pending")])
        await #expect(throws: AccountKeyProvisioning.Unavailable.self) {
            try await TerminalConnect.approve(link, api: api(), credentials: .tokenOnly(token: Vectors.token))
        }
    }
}

@Suite struct TerminalConnectRelayTests {
    private let current = URL(string: "https://happier.nomada.cloud")!
    private func link(_ server: String?) -> TerminalConnectLink {
        let suffix = server.map { "&server=\($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)" } ?? ""
        return TerminalConnectLink("happier://terminal?key=\(Vectors.key)\(suffix)")!
    }

    @Test func staysOnTheCurrentRelayWhenTheLinkNamesItOrNone() {
        #expect(TerminalConnect.relay(for: link(nil), current: current, known: []) == current)
        #expect(TerminalConnect.relay(for: link("https://happier.nomada.cloud/"), current: current, known: []) == current)
    }

    @Test func movesToTheLinksRelayAsTheWebAppDoes() {
        let saved = URL(string: "https://relay.example.com")!
        #expect(TerminalConnect.relay(for: link("https://relay.example.com/"), current: current, known: [current, saved]) == saved)
        #expect(TerminalConnect.relay(for: link("https://other.example.com"), current: current, known: [current]) == URL(string: "https://other.example.com"))
    }

    @Test func theCurrentOrASavedRelayIsRecognizedWhateverItsSpelling() {
        // A relay saved as typed (its sign-in is kept under that spelling) is the one the CLI writes
        // in lower case without the default port.
        let spelled = URL(string: "https://Happier.nomada.cloud:443")!
        #expect(TerminalConnect.relay(for: link("https://happier.nomada.cloud"), current: spelled, known: [spelled]) == spelled)
        let saved = URL(string: "https://Relay.Example.com")!
        #expect(TerminalConnect.relay(for: link("https://relay.example.com:443"), current: current, known: [current, saved]) == saved)
    }

    @Test func onlyAHostOnThisComputerIsLoopback() {
        // `isLoopbackHostname` (`@happier-dev/protocol`): 127.0.0.0/8, `localhost`, `*.localhost`, `::1`.
        let lookalike = link("http://127.0.0.1.evil.test")
        #expect(TerminalConnect.relay(for: lookalike, current: current, known: []) == URL(string: "http://127.0.0.1.evil.test"))
        #expect(TerminalConnect.relay(for: link("http://app.localhost:3005"), current: current, known: []) == current)
        #expect(TerminalConnect.relay(for: link("http://[::1]:3005"), current: current, known: []) == current)
    }

    @Test func aLoopbackRelayIsFollowedOnlyFromAnOpenedLink() {
        let loopback = link("http://127.0.0.1:3005")
        #expect(TerminalConnect.relay(for: loopback, current: current, known: [], allowsLoopback: false) == current)
        #expect(TerminalConnect.relay(for: loopback, current: current, known: [], allowsLoopback: true) == URL(string: "http://127.0.0.1:3005"))
        // Both on this computer: the current one serves it.
        let local = URL(string: "http://localhost:3005")!
        #expect(TerminalConnect.relay(for: loopback, current: local, known: [], allowsLoopback: true) == local)
    }
}

/// Records the URL each request reached the network with.
private final class QueryRecorder: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastURL: URL?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastURL = request.url
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite struct HTTPClientQueryTests {
    @Test func aPlusInAQueryValueReachesTheServerAsAPlus() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QueryRecorder.self]
        let http = HTTPClient(baseURL: URL(string: "https://relay.example.com")!, session: URLSession(configuration: configuration))

        _ = try await http.get("/v1/auth/request/status", query: ["publicKey": "a+b/c="])

        let query = try #require(QueryRecorder.lastURL?.query(percentEncoded: true))
        #expect(!query.contains("+"))
        // Decoded as a form (`+` is a space), the way the relay reads it.
        #expect(query.replacingOccurrences(of: "+", with: " ").removingPercentEncoding == "publicKey=a+b/c=")
    }
}

@Suite struct PendingTerminalConnectStoreTests {
    private func store() throws -> PendingTerminalConnectStore {
        PendingTerminalConnectStore(defaults: try #require(UserDefaults(suiteName: "pending-terminal-\(UUID().uuidString)")))
    }

    @Test func keepsALinkForTenMinutesFromWhenItWasOpened() throws {
        let store = try store()
        let link = try #require(TerminalConnectLink("happier://terminal?key=\(Vectors.key)&server=https%3A%2F%2Frelay.example.com"))
        let opened = Date(timeIntervalSince1970: 1_000_000)
        store.save(link, now: opened)
        #expect(store.load(now: opened.addingTimeInterval(599)) == link)

        // Moved to another relay later: the same request, still timed from when it was opened.
        let moved = link.retargeted(to: URL(string: "https://Other.Example:443")!)
        store.save(moved, now: opened.addingTimeInterval(300))
        #expect(store.load(now: opened.addingTimeInterval(500)) == moved)
        #expect(store.load(now: opened.addingTimeInterval(601)) == nil)
        #expect(store.load(now: opened) == nil)
    }

    @Test func dropsAPairedLinkOnceItExpires() throws {
        let store = try store()
        let link = try #require(TerminalConnectLink(Vectors.mobileLink)) // expires at 61 s
        store.save(link, now: Date(timeIntervalSince1970: 1))
        #expect(store.load(now: Date(timeIntervalSince1970: 60)) == link)
        #expect(store.load(now: Date(timeIntervalSince1970: 61)) == nil)
    }

    @Test func forgetsALinkOnRequest() throws {
        let store = try store()
        let link = TerminalConnectLink(Vectors.webLink)
        store.save(link, now: Date(timeIntervalSince1970: 1))
        #expect(link != nil && store.load(now: Date(timeIntervalSince1970: 2)) == link)
        store.save(nil)
        #expect(store.load(now: Date(timeIntervalSince1970: 2)) == nil)
    }
}

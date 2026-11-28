import CryptoKit
import Foundation

/// The link `happier auth login` prints for a signed-in device to approve: its QR and deep link
/// `happier://terminal?key=…&server=…&pairingSecret=…&createdAt=…&expiresAt=…`, the web link
/// `https://<web app>/terminal/connect#key=…` (query form too) and the legacy `happier://terminal?<key>`.
/// A port of `parseTerminalConnectUrl` (`apps/ui/sources/utils/path/terminalConnectUrl.ts`).
public struct TerminalConnectLink: Hashable, Sendable, Identifiable {
    /// What the CLI binds the answer to (`TerminalPairingAuthentication`); its HMAC key, as the link carries it.
    public struct Pairing: Hashable, Sendable {
        public let secret: String
        public let createdAtMs: Int64
        public let expiresAtMs: Int64

        public init(secret: String, createdAtMs: Int64, expiresAtMs: Int64) {
            self.secret = secret
            self.createdAtMs = createdAtMs
            self.expiresAtMs = expiresAtMs
        }
    }

    /// The computer's one-time box public key (32 bytes).
    public let publicKey: Data
    /// The relay the computer waits on; nil when the link doesn't say (or names a non-HTTP one).
    public let server: URL?
    public let pairing: Pairing?

    public var id: Data { publicKey }

    /// When the computer stops accepting an answer (V3 links only).
    public var expiresAt: Date? {
        pairing.map { Date(timeIntervalSince1970: TimeInterval($0.expiresAtMs) / 1000) }
    }

    public init?(_ text: String) {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let fields = Self.customSchemeFields(raw) ?? Self.webFields(raw),
              let key = Base64.decode(fields.key) else { return nil }
        self.init(publicKey: key, server: fields.server, pairing: fields.pairing)
    }

    init?(publicKey: Data, server: URL?, pairing: Pairing?) {
        guard publicKey.count == 32 else { return nil }
        self.publicKey = publicKey
        self.server = server
        self.pairing = pairing
    }

    /// The same request, answered on `server` instead: the relay the person chose while it waited
    /// (`retargetPendingTerminalConnectToServerUrl`).
    public func retargeted(to server: URL) -> TerminalConnectLink {
        TerminalConnectLink(publicKey: publicKey, server: server, pairing: pairing)!
    }

    private typealias Fields = (key: String, server: URL?, pairing: Pairing?)

    /// `happier*://terminal?…` (`parseHappierCustomSchemeUrl`): any scheme starting with `happier`,
    /// with `terminal` as host or path.
    private static func customSchemeFields(_ raw: String) -> Fields? {
        guard let colon = raw.firstIndex(of: ":") else { return nil }
        let scheme = raw[..<colon]
        guard let first = scheme.unicodeScalars.first, CharacterSet.letters.contains(first),
              scheme.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "+.-".unicodeScalars.contains($0) }),
              scheme.lowercased().hasPrefix("happier") else { return nil }
        var remainder = raw[raw.index(after: colon)...]
        if let hash = remainder.firstIndex(of: "#") { remainder = remainder[..<hash] }
        let location: Substring
        var tail: Substring = ""
        if let question = remainder.firstIndex(of: "?") {
            location = remainder[..<question]
            tail = remainder[remainder.index(after: question)...]
        } else {
            location = remainder
        }
        var host: Substring = ""
        var path = location
        if location.hasPrefix("//") {
            let authority = location.dropFirst(2)
            if authority.hasPrefix("/") {
                path = authority
            } else if let slash = authority.firstIndex(of: "/") {
                host = authority[..<slash]
                path = authority[slash...]
            } else {
                host = authority
                path = ""
            }
        }
        guard host == "terminal" || path == "terminal" || path == "/terminal", !tail.isEmpty else { return nil }
        // Legacy: the bare key, no parameters.
        guard tail.contains("=") || tail.contains("&") else { return (String(tail), nil, nil) }
        return fields(from: String(tail))
    }

    /// `http(s)://<web app>/terminal/connect`, parameters in the fragment, else in the query.
    private static func webFields(_ raw: String) -> Fields? {
        guard let url = URLComponents(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        guard path == "/terminal/connect" else { return nil }
        let source = url.percentEncodedFragment.flatMap { $0.isEmpty ? nil : $0 } ?? url.percentEncodedQuery ?? ""
        guard !source.isEmpty else { return nil }
        return fields(from: source)
    }

    private static func fields(from query: String) -> Fields? {
        let params = formParameters(query)
        let key = (params["key"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return (key, relay(params["server"] ?? ""), pairing(params))
    }

    /// `URLSearchParams.get`: `+` is a space, the first occurrence of a name wins.
    private static func formParameters(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ value: Substring) -> String {
                let spaced = value.replacingOccurrences(of: "+", with: " ")
                return spaced.removingPercentEncoding ?? spaced
            }
            let name = decode(parts[0])
            if result[name] == nil { result[name] = parts.count > 1 ? decode(parts[1]) : "" }
        }
        return result
    }

    /// `normalizeServerUrl`: an absolute http(s) URL, through this app's one owner of relay addresses
    /// (`ServerAddress`), which keeps the spelling; `RelayList.canonical` says which relay it is.
    private static func relay(_ value: String) -> URL? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains("://") else { return nil }
        return ServerAddress.normalize(text)
    }

    /// `parsePairingContext`: kept only with a secret and a valid window, else the link is a V2 one.
    private static func pairing(_ params: [String: String]) -> Pairing? {
        let secret = (params["pairingSecret"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty, let created = safeInteger(params["createdAt"]), let expires = safeInteger(params["expiresAt"]),
              created >= 0, expires > created else { return nil }
        return Pairing(secret: secret, createdAtMs: created, expiresAtMs: expires)
    }

    /// `Number(value)` that `Number.isSafeInteger` accepts (a missing value is 0, as in JavaScript).
    private static func safeInteger(_ value: String?) -> Int64? {
        let text = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return 0 }
        guard let number = Double(text), number.isFinite, number == number.rounded(), abs(number) <= 9_007_199_254_740_991 else { return nil }
        return Int64(number)
    }
}

/// The sealed answers a terminal opens (`packages/protocol/src/crypto/terminalProvisioningV2.ts`).
public enum TerminalProvisioning {
    public struct InvalidInput: Error {}

    private static let v3Magic = Data("HPV3".utf8)
    private static let v3MacDomain = "happier-terminal-provisioning-v3"

    /// `[0x00] ‖ content private key`, sealed for the terminal.
    public static func sealV2(contentPrivateKey: Data, recipient: Data, random: (Int) -> Data = HappierCrypto.randomBytes) throws -> Data {
        guard contentPrivateKey.count == 32 else { throw InvalidInput() }
        return try HappierCrypto.sealBoxBundle(Data([0]) + contentPrivateKey, recipientPublicKey: recipient, random: random)
    }

    /// `[0x01]`: a token-only Account; the terminal keeps only the token.
    public static func sealV2TokenOnly(recipient: Data, random: (Int) -> Data = HappierCrypto.randomBytes) throws -> Data {
        try HappierCrypto.sealBoxBundle(Data([1]), recipientPublicKey: recipient, random: random)
    }

    /// `"HPV3" ‖ V2 ‖ HMAC-SHA256(pairing secret, LD[domain, terminal key, created, expires, V2])`:
    /// the terminal knows the answer came from whoever read its link, not from the relay.
    public static func sealV3(contentPrivateKey: Data, recipient: Data, pairing: TerminalConnectLink.Pairing,
                              random: (Int) -> Data = HappierCrypto.randomBytes) throws -> Data {
        let secret = try v3Secret(recipient: recipient, pairing: pairing)
        return authenticated(try sealV2(contentPrivateKey: contentPrivateKey, recipient: recipient, random: random),
                             recipient: recipient, pairing: pairing, secret: secret)
    }

    public static func sealV3TokenOnly(recipient: Data, pairing: TerminalConnectLink.Pairing,
                                       random: (Int) -> Data = HappierCrypto.randomBytes) throws -> Data {
        let secret = try v3Secret(recipient: recipient, pairing: pairing)
        return authenticated(try sealV2TokenOnly(recipient: recipient, random: random), recipient: recipient, pairing: pairing, secret: secret)
    }

    /// `assertTerminalProvisioningV3Context`.
    private static func v3Secret(recipient: Data, pairing: TerminalConnectLink.Pairing) throws -> Data {
        guard recipient.count == 32, let secret = Base64.decode(pairing.secret), secret.count == 32,
              pairing.createdAtMs >= 0, pairing.expiresAtMs > pairing.createdAtMs else { throw InvalidInput() }
        return secret
    }

    private static func authenticated(_ sealedV2: Data, recipient: Data, pairing: TerminalConnectLink.Pairing, secret: Data) -> Data {
        let message = lengthDelimited([Data(v3MacDomain.utf8), recipient, Data(String(pairing.createdAtMs).utf8),
                                       Data(String(pairing.expiresAtMs).utf8), sealedV2])
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret))
        return v3Magic + sealedV2 + Data(mac)
    }

    /// `encodeCanonicalLengthDelimited`: each part after its length as a big-endian UInt32.
    static func lengthDelimited(_ parts: [Data]) -> Data {
        var output = Data()
        for part in parts {
            withUnsafeBytes(of: UInt32(part.count).bigEndian) { output.append(contentsOf: $0) }
            output.append(part)
        }
        return output
    }
}

/// Approving a computer's sign-in from this device (`useConnectTerminal.ts` over `authApprove`).
public enum TerminalConnect {
    public enum Outcome: Equatable, Sendable {
        case approved
        /// Another device answered first (`already_authorized`).
        case alreadyUsed
        /// The relay no longer has the request (`not_found`, or gone by the time of the answer).
        case expired
        /// The link's relay has no sign-in on this device; it waits for one.
        case needsSignIn(URL)
    }

    /// `GET /v1/auth/request/status`.
    public struct RequestStatus: Equatable, Sendable {
        public enum State: String, Sendable { case notFound = "not_found", pending, authorized }
        public let state: State
        public let supportsV2: Bool
        public let supportsTokenOnly: Bool

        public init(state: State, supportsV2: Bool, supportsTokenOnly: Bool) {
            self.state = state
            self.supportsV2 = supportsV2
            self.supportsTokenOnly = supportsTokenOnly
        }
    }

    /// No answer the computer understands (`AuthApproveUnsupportedResponseError`).
    public struct Unsupported: LocalizedError {
        public var errorDescription: String? {
            String(localized: "The Happier CLI on this computer is too old to sign in from here. Update it, then run happier auth login again.")
        }
    }

    /// The relay answered the status with something else than the three states it defines.
    public struct UnexpectedStatus: LocalizedError {
        public var errorDescription: String? { String(localized: "The relay gave an unexpected answer. Try again.") }
    }

    /// Checks this device's key with the relay, then answers a pending request once.
    public static func approve(_ link: TerminalConnectLink, api: HappierAPI, credentials: Credentials,
                               random: (Int) -> Data = HappierCrypto.randomBytes) async throws -> Outcome {
        try await api.verifyAccountKeyForProvisioning(credentials)
        let status = try await api.terminalAuthStatus(publicKey: link.publicKey)
        switch status.state {
        case .notFound: return .expired
        case .authorized: return .alreadyUsed
        case .pending:
            let payload = try response(status: status, credentials: credentials, link: link, random: random)
            do {
                try await api.approveTerminal(publicKey: link.publicKey, response: payload)
            } catch let error as HTTPClient.ServerError where error.status == 404 {
                // The relay answers 404 only for a request that's gone or expired.
                return .expired
            }
            return .approved
        }
    }

    /// The answer `authApprove` picks: token-only for a keyless Account when the terminal takes it,
    /// otherwise the content key; V3 when the link carries a pairing. The web app's V1 (the bare
    /// recovery secret, off by default) isn't offered.
    static func response(status: RequestStatus, credentials: Credentials, link: TerminalConnectLink,
                         random: (Int) -> Data = HappierCrypto.randomBytes) throws -> Data {
        let contentKey = try credentials.accountKeys()?.content.secretKey
        if status.supportsV2, status.supportsTokenOnly, contentKey == nil {
            if let pairing = link.pairing { return try TerminalProvisioning.sealV3TokenOnly(recipient: link.publicKey, pairing: pairing, random: random) }
            return try TerminalProvisioning.sealV2TokenOnly(recipient: link.publicKey, random: random)
        }
        if status.supportsV2, let contentKey {
            if let pairing = link.pairing {
                return try TerminalProvisioning.sealV3(contentPrivateKey: contentKey, recipient: link.publicKey, pairing: pairing, random: random)
            }
            return try TerminalProvisioning.sealV2(contentPrivateKey: contentKey, recipient: link.publicKey, random: random)
        }
        throw Unsupported()
    }

    /// The relay the approval goes to (`resolveEffectiveServerUrlOverride`): the current one when
    /// the link names it or none, otherwise the link's (a saved spelling of it when there is one).
    /// A loopback relay is followed only from an opened or pasted link, not a scanned code: on
    /// another device it would be unreachable. With both on this computer the current one serves it.
    public static func relay(for link: TerminalConnectLink, current: URL, known: [URL], allowsLoopback: Bool = false) -> URL {
        guard let requested = link.server, RelayList.canonical(requested) != RelayList.canonical(current) else { return current }
        if ServerAddress.isLoopback(requested), !allowsLoopback || ServerAddress.isLoopback(current) { return current }
        return known.first { RelayList.canonical($0) == RelayList.canonical(requested) } ?? requested
    }
}

/// The opened link that waits for this device to sign in, kept through a relaunch as the web app
/// keeps it (`pendingTerminalConnect.shared.ts`): for ten minutes from when it was opened, and never
/// past the link's own expiry.
struct PendingTerminalConnectStore {
    static let lifetime: TimeInterval = 10 * 60
    static let key = "happier.pendingTerminalConnect"

    let defaults: UserDefaults

    private struct Record: Codable {
        let publicKey: Data
        let server: URL?
        let pairingSecret: String?
        let createdAtMs: Int64?
        let expiresAtMs: Int64?
        let savedAt: Date

        var link: TerminalConnectLink? {
            var pairing: TerminalConnectLink.Pairing?
            if let pairingSecret, let createdAtMs, let expiresAtMs {
                pairing = .init(secret: pairingSecret, createdAtMs: createdAtMs, expiresAtMs: expiresAtMs)
            }
            return TerminalConnectLink(publicKey: publicKey, server: server, pairing: pairing)
        }
    }

    /// Keeps `link` (nil forgets it). The same request saved again (moved to another relay) keeps
    /// the time it was first opened, as `setPendingTerminalConnect` does.
    func save(_ link: TerminalConnectLink?, now: Date = .now) {
        guard let link else { return defaults.removeObject(forKey: Self.key) }
        let previous = record()
        let savedAt = previous.flatMap { $0.publicKey == link.publicKey && $0.link?.pairing == link.pairing ? $0.savedAt : nil } ?? now
        let record = Record(publicKey: link.publicKey, server: link.server, pairingSecret: link.pairing?.secret,
                            createdAtMs: link.pairing?.createdAtMs, expiresAtMs: link.pairing?.expiresAtMs, savedAt: savedAt)
        guard let data = try? JSONEncoder().encode(record) else { return defaults.removeObject(forKey: Self.key) }
        defaults.set(data, forKey: Self.key)
    }

    /// The kept link, unless it's older than `lifetime` or past its expiry (then it's forgotten).
    func load(now: Date = .now) -> TerminalConnectLink? {
        guard let record = record() else { return nil }
        guard let link = record.link, now.timeIntervalSince(record.savedAt) <= Self.lifetime,
              link.expiresAt.map({ now < $0 }) ?? true else {
            defaults.removeObject(forKey: Self.key)
            return nil
        }
        return link
    }

    private func record() -> Record? {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
    }
}

extension HappierAPI {
    /// A kept credential is custody, not proof its key is still the Account's: before handing keys to
    /// another device or computer, check them against what the relay publishes now
    /// (`assertCurrentAccountKeyForProvisioning`). Plain Accounts have no key to check.
    public func verifyAccountKeyForProvisioning(_ credentials: Credentials) async throws {
        guard try await accountIsEncrypted() else { return }
        guard let accountId = credentials.accountId,
              let profile = try await accountLinkProfile(accountId: accountId) else { throw AccountKeyProvisioning.Unavailable() }
        try AccountKeyProvisioning.verify(encrypted: true, account: profile, credentials: credentials)
    }

    /// Whether a computer's sign-in request is waiting (`GET /v1/auth/request/status`), asked
    /// without the account's token as `authApprove` does.
    public func terminalAuthStatus(publicKey: Data) async throws -> TerminalConnect.RequestStatus {
        var anonymous = http
        anonymous.token = nil
        let response = try await anonymous.get("/v1/auth/request/status", query: ["publicKey": publicKey.base64EncodedString()])
        guard let state = response["status"]?.stringValue.flatMap(TerminalConnect.RequestStatus.State.init(rawValue:)) else {
            throw TerminalConnect.UnexpectedStatus()
        }
        return .init(state: state, supportsV2: response["supportsV2"]?.boolValue == true,
                     supportsTokenOnly: response["supportsTokenOnly"]?.boolValue == true)
    }

    /// Hands the sealed answer to the waiting computer (`POST /v1/auth/response`); the relay keeps
    /// only the first one.
    public func approveTerminal(publicKey: Data, response: Data) async throws {
        _ = try await http.post("/v1/auth/response", [
            "publicKey": .string(publicKey.base64EncodedString()),
            "response": .string(response.base64EncodedString()),
        ])
    }
}

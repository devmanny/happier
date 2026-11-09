import Foundation

/// Sign-in flows for a new device (`apps/ui/sources/auth/flows/**`, `docs/api.md`).
public struct AuthAPI: Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case rejected(String)
        case expired
        case invalidPairingLink

        public var description: String {
            switch self {
            case .rejected(let reason): "Sign-in rejected: \(reason)"
            case .expired: "The sign-in request expired. Try again."
            case .invalidPairingLink: "This QR code is not a Happier pairing code."
            }
        }
    }

    private let http: HTTPClient

    public init(server: URL, session: URLSession = HTTPClient.relaySession) {
        http = HTTPClient(baseURL: server, session: session)
    }

    // MARK: Restore with secret key, or a new account (POST /v1/auth challenge)

    public func signIn(secret: Data) async throws -> Credentials {
        try await authenticate(secret: secret, publishContentKey: false)
    }

    /// What the relay allows a new device to do (`GET /v1/features`).
    public func options() async throws -> AuthOptions {
        AuthOptions(features: try await http.get("/v1/features"))
    }

    /// A new account under a new device key (`createAccount` in `index.tsx`): `/v1/auth` creates
    /// it for a key it doesn't know. Returns the key, which only this device then holds; show it
    /// for safekeeping.
    public func createAccount(publishContentKey: Bool) async throws -> (credentials: Credentials, secret: Data) {
        let secret = HappierCrypto.randomBytes(32)
        do {
            return (try await authenticate(secret: secret, publishContentKey: publishContentKey), secret)
        } catch let error as HTTPClient.ServerError where error.status == 403 && error.body?["error"]?.stringValue == "signup-disabled" {
            throw Failure.rejected(String(localized: "This relay doesn't accept new accounts."))
        }
    }

    private func authenticate(secret: Data, publishContentKey: Bool) async throws -> Credentials {
        let keys = try AccountKeys(masterSecret: secret)
        let response = try await http.post("/v1/auth", try Self.challengeBody(keys: keys, challenge: HappierCrypto.randomBytes(32),
                                                                             publishContentKey: publishContentKey))
        guard let token = response["token"]?.stringValue else {
            throw Failure.rejected(response["error"]?.stringValue ?? "no token")
        }
        return .legacy(token: token, secret: secret)
    }

    /// `getToken.ts`: the Ed25519 key signs a fresh challenge; with sharing content keys on, the
    /// account's X25519 content key is published, signed by the same key.
    static func challengeBody(keys: AccountKeys, challenge: Data, publishContentKey: Bool) throws -> JSONValue {
        guard let publicKey = keys.signingPublicKey else { throw Failure.rejected("invalid secret") }
        var body: [String: JSONValue] = [
            "publicKey": .string(publicKey.base64EncodedString()),
            "challenge": .string(challenge.base64EncodedString()),
            "signature": .string(try keys.sign(challenge).base64EncodedString()),
        ]
        if publishContentKey {
            let content = keys.content.publicKey
            body["contentPublicKey"] = .string(content.base64EncodedString())
            body["contentPublicKeySig"] = .string(try keys.sign(AccountKeyProvisioning.contentKeyBindingMessage(content)).base64EncodedString())
        }
        return .object(body)
    }

    // MARK: Link from a signed-in device (new device shows a QR)

    /// Registers the account-link request; show `pair.accountLinkURL` as a QR code, then call `waitForApproval`.
    public func startAccountLink() async throws -> LinkKeyPair {
        let pair = try LinkKeyPair.generate()
        _ = try await http.post("/v1/auth/account/request", ["publicKey": .string(pair.publicKey.base64EncodedString())])
        return pair
    }

    /// Polls until another device approves (`qrWait.ts`, 1 s cadence). Cancel the task to stop.
    public func waitForApproval(_ pair: LinkKeyPair) async throws -> Credentials {
        let body: JSONValue = ["publicKey": .string(pair.publicKey.base64EncodedString())]
        var useV1 = false
        while true {
            try Task.checkCancellation()
            let response: JSONValue
            do {
                response = try await http.post(useV1 ? "/v1/auth/account/request" : "/v2/auth/account/request", body)
            } catch let error as HTTPClient.ServerError where error.status == 404 && !useV1 {
                useV1 = true
                continue
            } catch let error as HTTPClient.ServerError where error.status == 404 || error.status == 410 {
                throw Failure.expired
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            }
            if response["state"]?.stringValue == "authorized", let sealed = response["response"]?.stringValue {
                let token: String
                if let encrypted = response["tokenEncrypted"]?.stringValue {
                    token = try pair.openToken(encrypted)
                } else if let plain = response["token"]?.stringValue {
                    token = plain
                } else {
                    throw Failure.rejected("missing token")
                }
                return try pair.openLinkResponse(sealed, token: token)
            }
            try await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: Scan a desktop/web pairing QR (`happier:///pair?v=1&pairId=…&secret=…&server=…`)

    public struct PairingLink: Sendable, Equatable {
        public let pairId: String
        public let secret: String
        public let server: URL?

        public init?(_ text: String) {
            guard let components = URLComponents(string: text), components.scheme == "happier",
                  components.path.hasSuffix("pair") || components.host == "pair"
            else { return nil }
            let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
            guard let pairId = query["pairId"], !pairId.isEmpty, let secret = query["secret"], !secret.isEmpty else { return nil }
            self.pairId = pairId
            self.secret = secret
            self.server = query["server"].flatMap(URL.init(string:))
        }
    }

    /// Requests pairing; returns the device keypair and the confirmation code to display.
    public func requestPairing(_ link: PairingLink, deviceLabel: String) async throws -> (pair: LinkKeyPair, confirmCode: String) {
        let pair = try await startAccountLink()
        let response = try await http.post("/v1/auth/pairing/request", [
            "pairId": .string(link.pairId),
            "secret": .string(link.secret),
            "publicKey": .string(pair.publicKey.base64EncodedString()),
            "supportsCredentialVariants": true,
            "deviceLabel": .string(deviceLabel),
        ])
        return (pair, response["confirmCode"]?.stringValue ?? "")
    }

}

/// The sign-in options a relay offers (`useRemoteAuthEntryOptions.ts` over `/v1/features`).
public struct AuthOptions: Sendable, Equatable {
    /// A new device key can create an account here (key-challenge `provision`).
    public let canCreateAccount: Bool
    /// New accounts publish their content key (`features.sharing.contentKeys`).
    public let publishesContentKey: Bool

    public init(features: JSONValue) {
        let keyChallengeEnabled = features["features"]?["auth"]?["login"]?["keyChallenge"]?["enabled"]?.boolValue != false
        let auth = features["capabilities"]?["auth"]
        let canProvision: Bool
        if let methods = auth?["methods"]?.arrayValue {
            let keyChallenge = methods.first { $0["id"]?.stringValue == "key_challenge" }
            canProvision = keyChallenge?["actions"]?.arrayValue?.contains {
                $0["id"]?.stringValue == "provision" && $0["enabled"]?.boolValue == true
                    && ["keyed", "either"].contains($0["mode"]?.stringValue ?? "keyed")
            } ?? false
        } else if let signup = auth?["signup"]?["methods"]?.arrayValue {
            canProvision = signup.contains { $0["id"]?.stringValue == "anonymous" && $0["enabled"]?.boolValue == true }
        } else {
            // Relays from before auth capabilities: anonymous sign-up only.
            canProvision = true
        }
        canCreateAccount = keyChallengeEnabled && canProvision
        publishesContentKey = features["features"]?["sharing"]?["contentKeys"]?["enabled"]?.boolValue == true
    }
}

import Foundation

/// The three credential shapes stored by the TypeScript UI (`auth/storage/tokenStorage.ts`).
/// The Codable form matches its JSON so stored credentials stay interchangeable.
public enum Credentials: Sendable, Equatable {
    /// Master secret known: `{token, secret}` (secret is base64url).
    case legacy(token: String, secret: Data)
    /// Content keypair only: `{token, encryption: {publicKey, machineKey}}` (standard base64).
    case dataKey(token: String, content: ContentKeyPair)
    /// Keyless account: `{token}`. Only plaintext sessions are readable.
    case tokenOnly(token: String)

    public var token: String {
        switch self {
        case .legacy(let token, _), .dataKey(let token, _), .tokenOnly(let token): token
        }
    }

    /// Key material, or nil for token-only accounts.
    public func accountKeys() throws -> AccountKeys? {
        switch self {
        case .legacy(_, let secret): try AccountKeys(masterSecret: secret)
        case .dataKey(_, let content): AccountKeys(content: content)
        case .tokenOnly: nil
        }
    }

    /// Account id: the `sub` claim of the JWT-shaped token (`utils/auth/parseToken.ts`).
    public var accountId: String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2, let payload = Base64.decode(String(parts[1])) else { return nil }
        return (try? JSONValue.parse(payload))?["sub"]?.stringValue
    }
}

extension Credentials: Codable {
    private enum Keys: String, CodingKey { case token, secret, encryption }
    private enum EncryptionKeys: String, CodingKey { case publicKey, machineKey }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let token = try c.decode(String.self, forKey: .token)
        if let secret = try c.decodeIfPresent(String.self, forKey: .secret) {
            guard let bytes = Base64.decode(secret) else {
                throw DecodingError.dataCorruptedError(forKey: .secret, in: c, debugDescription: "invalid secret")
            }
            self = .legacy(token: token, secret: bytes)
        } else if c.contains(.encryption) {
            let e = try c.nestedContainer(keyedBy: EncryptionKeys.self, forKey: .encryption)
            guard let pk = Base64.decode(try e.decode(String.self, forKey: .publicKey)),
                  let sk = Base64.decode(try e.decode(String.self, forKey: .machineKey))
            else { throw DecodingError.dataCorruptedError(forKey: .encryption, in: c, debugDescription: "invalid keys") }
            self = .dataKey(token: token, content: ContentKeyPair(publicKey: pk, secretKey: sk))
        } else {
            self = .tokenOnly(token: token)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(token, forKey: .token)
        switch self {
        case .legacy(_, let secret):
            try c.encode(Base64.urlEncoded(secret), forKey: .secret)
        case .dataKey(_, let content):
            var e = c.nestedContainer(keyedBy: EncryptionKeys.self, forKey: .encryption)
            try e.encode(content.publicKey.base64EncodedString(), forKey: .publicKey)
            try e.encode(content.secretKey.base64EncodedString(), forKey: .machineKey)
        case .tokenOnly:
            break
        }
    }
}

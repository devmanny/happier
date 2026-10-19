import CryptoKit
import Foundation

/// X25519 keypair that opens every `dataEncryptionKey` of the account.
public struct ContentKeyPair: Sendable, Equatable {
    public let publicKey: Data
    /// Called `machineKey` in the TypeScript credentials.
    public let secretKey: Data

    public init(publicKey: Data, secretKey: Data) {
        self.publicKey = publicKey
        self.secretKey = secretKey
    }
}

/// Key material for an E2EE account (`apps/ui/sources/sync/encryption/encryption.ts`).
public struct AccountKeys: Sendable {
    /// 32-byte recovery secret; nil for dataKey credentials (content keypair only).
    public let masterSecret: Data?
    public let content: ContentKeyPair

    public init(masterSecret: Data) throws {
        guard masterSecret.count == 32 else { throw HappierCrypto.Failure.invalidLength }
        self.masterSecret = masterSecret
        let contentSeed = HappierCrypto.deriveKey(master: masterSecret, usage: "Happy EnCoder", path: ["content"])
        let secret = HappierCrypto.boxSecretKey(fromSeed: contentSeed)
        self.content = ContentKeyPair(publicKey: try HappierCrypto.boxPublicKey(secretKey: secret), secretKey: secret)
    }

    public init(content: ContentKeyPair) {
        self.masterSecret = nil
        self.content = content
    }

    /// Ed25519 public key registered as the account identity (`crypto_sign_seed_keypair(master)`).
    public var signingPublicKey: Data? {
        signingKey.map { $0.publicKey.rawRepresentation }
    }

    private var signingKey: Curve25519.Signing.PrivateKey? {
        masterSecret.flatMap { try? Curve25519.Signing.PrivateKey(rawRepresentation: $0) }
    }

    public func sign(_ message: Data) throws -> Data {
        guard let signingKey else { throw HappierCrypto.Failure.invalidLength }
        return try signingKey.signature(for: message)
    }

    /// Cipher used when a session/machine has no published `dataEncryptionKey` (legacy records).
    public var fallbackCipher: ContentCipher {
        if let masterSecret { return .secretbox(key: masterSecret) }
        return .aesGCM(key: content.secretKey)
    }

    /// Resolves the content cipher for a record's base64 `dataEncryptionKey`.
    public func cipher(forDataEncryptionKey base64: String?) -> ContentCipher? {
        guard let base64, !base64.isEmpty else { return fallbackCipher }
        guard let envelope = Base64.decode(base64),
              let dataKey = HappierCrypto.openDataKeyEnvelope(envelope, secretKey: content.secretKey)
        else { return nil }
        return .aesGCM(key: dataKey)
    }
}

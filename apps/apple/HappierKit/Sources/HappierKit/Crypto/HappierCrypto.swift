import Clibsodium
import CryptoKit
import Foundation
import Security

/// Crypto primitives shared with the TypeScript clients (`packages/protocol/src/crypto`, `apps/ui/sources/encryption`).
/// NaCl box/secretbox come from libsodium; AES-GCM, HMAC and SHA from CryptoKit.
public enum HappierCrypto {
    public enum Failure: Error { case sodium, invalidLength, randomUnavailable }

    static let sodiumReady: Bool = sodium_init() >= 0

    public static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return data
    }

    // MARK: Key derivation (HMAC-SHA512 tree, `deriveKey.ts`)

    public static func deriveKey(master: Data, usage: String, path: [String]) -> Data {
        var (key, chain) = split(HMAC<SHA512>.authenticationCode(for: master, using: SymmetricKey(data: Data((usage + " Master Seed").utf8))))
        for index in path {
            (key, chain) = split(HMAC<SHA512>.authenticationCode(for: Data([0]) + Data(index.utf8), using: SymmetricKey(data: chain)))
        }
        return key
    }

    private static func split(_ mac: HMAC<SHA512>.MAC) -> (Data, Data) {
        let bytes = Data(mac)
        return (bytes.prefix(32), bytes.suffix(32))
    }

    // MARK: X25519 / NaCl box

    /// `crypto_box_seed_keypair` secret: SHA-512(seed)[0..<32].
    public static func boxSecretKey(fromSeed seed: Data) -> Data { Data(SHA512.hash(data: seed)).prefix(32) }

    public static func boxPublicKey(secretKey: Data) throws -> Data {
        guard sodiumReady, secretKey.count == 32 else { throw Failure.invalidLength }
        var publicKey = Data(count: 32)
        let status = publicKey.withUnsafeMutableBytes { pk in
            secretKey.withUnsafeBytes { sk in crypto_scalarmult_base(pk.bindMemory(to: UInt8.self).baseAddress!, sk.bindMemory(to: UInt8.self).baseAddress!) }
        }
        guard status == 0 else { throw Failure.sodium }
        return publicKey
    }

    /// Box bundle: `ephemeralPublicKey(32) ‖ nonce(24) ‖ crypto_box_easy(plaintext)`.
    public static func sealBoxBundle(_ plaintext: Data, recipientPublicKey: Data, random: (Int) -> Data = randomBytes) throws -> Data {
        guard sodiumReady, recipientPublicKey.count == 32 else { throw Failure.invalidLength }
        let ephemeralSecret = random(32)
        let ephemeralPublic = try boxPublicKey(secretKey: ephemeralSecret)
        let nonce = random(24)
        var cipher = Data(count: plaintext.count + 16)
        let status = cipher.withUnsafeMutableBytes { c in
            plaintext.withUnsafeBytes { m in nonce.withUnsafeBytes { n in recipientPublicKey.withUnsafeBytes { pk in ephemeralSecret.withUnsafeBytes { sk in
                crypto_box_easy(c.u8, m.u8, UInt64(plaintext.count), n.u8, pk.u8, sk.u8)
            } } } }
        }
        guard status == 0 else { throw Failure.sodium }
        return ephemeralPublic + nonce + cipher
    }

    /// Opens a box bundle. Like `openBoxBundle` in TS, retries with `SHA-512(secret)[0..<32]`
    /// so both raw box secrets and box seeds are accepted.
    public static func openBoxBundle(_ bundle: Data, secretKey: Data) -> Data? {
        guard sodiumReady, bundle.count >= 32 + 24 + 16, secretKey.count == 32 else { return nil }
        return openBox(bundle, secretKey: secretKey) ?? openBox(bundle, secretKey: boxSecretKey(fromSeed: secretKey))
    }

    private static func openBox(_ bundle: Data, secretKey: Data) -> Data? {
        let bytes = Data(bundle)
        let ephemeralPublic = bytes.prefix(32)
        let nonce = bytes.dropFirst(32).prefix(24)
        let cipher = bytes.dropFirst(56)
        var plain = Data(count: cipher.count - 16)
        let status = plain.withUnsafeMutableBytes { m in
            cipher.withUnsafeBytes { c in nonce.withUnsafeBytes { n in ephemeralPublic.withUnsafeBytes { pk in secretKey.withUnsafeBytes { sk in
                crypto_box_open_easy(m.u8, c.u8, UInt64(cipher.count), n.u8, pk.u8, sk.u8)
            } } } }
        }
        return status == 0 ? plain : nil
    }

    /// Encrypted data-key envelope V1: `0x00 ‖ boxBundle(dataKey)`.
    public static func openDataKeyEnvelope(_ envelope: Data, secretKey: Data) -> Data? {
        guard envelope.first == 0 else { return nil }
        return openBoxBundle(Data(envelope.dropFirst()), secretKey: secretKey)
    }

    public static func sealDataKeyEnvelope(_ dataKey: Data, recipientPublicKey: Data) throws -> Data {
        Data([0]) + (try sealBoxBundle(dataKey, recipientPublicKey: recipientPublicKey))
    }

    // MARK: Secretbox (XSalsa20-Poly1305)

    static func secretboxSeal(_ plaintext: Data, key: Data, nonce: Data) throws -> Data {
        guard sodiumReady, key.count == 32, nonce.count == 24 else { throw Failure.invalidLength }
        var cipher = Data(count: plaintext.count + 16)
        let status = cipher.withUnsafeMutableBytes { c in
            plaintext.withUnsafeBytes { m in nonce.withUnsafeBytes { n in key.withUnsafeBytes { k in
                crypto_secretbox_easy(c.u8, m.u8, UInt64(plaintext.count), n.u8, k.u8)
            } } }
        }
        guard status == 0 else { throw Failure.sodium }
        return cipher
    }

    static func secretboxOpen(_ cipher: Data, key: Data, nonce: Data) -> Data? {
        guard sodiumReady, key.count == 32, nonce.count == 24, cipher.count >= 16 else { return nil }
        var plain = Data(count: cipher.count - 16)
        let status = plain.withUnsafeMutableBytes { m in
            cipher.withUnsafeBytes { c in nonce.withUnsafeBytes { n in key.withUnsafeBytes { k in
                crypto_secretbox_open_easy(m.u8, c.u8, UInt64(cipher.count), n.u8, k.u8)
            } } }
        }
        return status == 0 ? plain : nil
    }
}

private extension UnsafeRawBufferPointer {
    var u8: UnsafePointer<UInt8> { bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(bitPattern: 1)! }
}

private extension UnsafeMutableRawBufferPointer {
    var u8: UnsafeMutablePointer<UInt8> { bindMemory(to: UInt8.self).baseAddress ?? UnsafeMutablePointer(bitPattern: 1)! }
}

import CryptoKit
import Foundation

/// Content encryption for session/machine documents and messages (`docs/encryption.md`).
public enum ContentCipher: Sendable {
    /// dataKey variant: `0x00 ‖ nonce(12) ‖ ciphertext ‖ tag(16)`.
    case aesGCM(key: Data)
    /// Legacy variant: `nonce(24) ‖ secretbox(tag ‖ ciphertext)`.
    case secretbox(key: Data)

    public enum Failure: Error { case unsupportedVersion, malformed, authentication }

    // MARK: Bytes

    public func seal(_ plaintext: Data, nonce: Data? = nil) throws -> Data {
        switch self {
        case .aesGCM(let key):
            let nonce = try AES.GCM.Nonce(data: nonce ?? HappierCrypto.randomBytes(12))
            let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce)
            return Data([0]) + box.combined!
        case .secretbox(let key):
            let nonce = nonce ?? HappierCrypto.randomBytes(24)
            return nonce + (try HappierCrypto.secretboxSeal(plaintext, key: key, nonce: nonce))
        }
    }

    public func open(_ data: Data) throws -> Data {
        let bytes = Data(data)
        switch self {
        case .aesGCM(let key):
            guard let version = bytes.first else { throw Failure.malformed }
            guard version == 0 else { throw Failure.unsupportedVersion }
            guard bytes.count >= 1 + 12 + 16 else { throw Failure.malformed }
            do {
                return try AES.GCM.open(AES.GCM.SealedBox(combined: bytes.dropFirst()), using: SymmetricKey(data: key))
            } catch { throw Failure.authentication }
        case .secretbox(let key):
            guard bytes.count >= 24 + 16 else { throw Failure.malformed }
            guard let plain = HappierCrypto.secretboxOpen(Data(bytes.dropFirst(24)), key: key, nonce: bytes.prefix(24)) else {
                throw Failure.authentication
            }
            return plain
        }
    }

    // MARK: JSON documents (`serializedJsonValue.ts` wrapper)

    public func encrypt(_ value: JSONValue, nonce: Data? = nil) throws -> Data {
        try seal(SerializedJSON.encode(value), nonce: nonce)
    }

    public func decrypt(_ data: Data) throws -> JSONValue {
        try SerializedJSON.decode(open(data))
    }

    public func encryptBase64(_ value: JSONValue) throws -> String {
        try encrypt(value).base64EncodedString()
    }

    public func decryptBase64(_ base64: String) throws -> JSONValue {
        guard let data = Base64.decode(base64) else { throw Failure.malformed }
        return try decrypt(data)
    }
}

/// `{"__happierSerializedJsonValueV1":true,"type":"json","value":…}` — writers always wrap,
/// readers accept the wrapper or bare JSON.
enum SerializedJSON {
    static func encode(_ value: JSONValue) throws -> Data {
        // Key order is fixed to match the TypeScript writer byte-for-byte.
        Data(#"{"__happierSerializedJsonValueV1":true,"type":"json","value":"#.utf8) + (try value.encoded()) + Data("}".utf8)
    }

    static func decode(_ data: Data) throws -> JSONValue {
        let parsed = try JSONValue.parse(data)
        guard parsed["__happierSerializedJsonValueV1"]?.boolValue == true else { return parsed }
        switch parsed["type"]?.stringValue {
        case "json": return parsed["value"] ?? .null
        case "undefined": return .null
        default: throw ContentCipher.Failure.malformed
        }
    }
}

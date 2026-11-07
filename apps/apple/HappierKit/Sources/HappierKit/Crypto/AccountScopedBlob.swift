import CryptoKit
import Foundation

/// Account-scoped records sealed for the account's own devices (`packages/protocol/src/crypto/accountScopedCipher.ts`):
/// `0xA1 ‖ kind ‖ nonce(24) ‖ secretbox(json)`, keyed by HMAC-SHA512(machineKey, "happier:account_scoped:<kind>:v1").
public enum AccountScopedBlob {
    public enum Kind: UInt8, Sendable {
        case accountSettings = 1
        case providerAccountUsageSnapshot = 6
        case agentProfile = 11
        case agentPresence = 12
        case agentMemory = 13

        var name: String {
            switch self {
            case .accountSettings: "account_settings"
            case .providerAccountUsageSnapshot: "provider_account_usage_snapshot"
            case .agentProfile: "agent_profile"
            case .agentPresence: "agent_presence"
            case .agentMemory: "agent_memory"
            }
        }
    }

    private static let magic: UInt8 = 0xA1
    private static let nonceLength = 24

    /// The JSON inside, or nil when it isn't this kind or doesn't open with this key.
    public static func open(_ base64: String, kind: Kind, machineKey: Data) -> JSONValue? {
        guard let bytes = Base64.decode(base64), bytes.count >= 2 + nonceLength + 16,
              bytes[bytes.startIndex] == magic, bytes[bytes.startIndex + 1] == kind.rawValue else { return nil }
        let body = bytes.dropFirst(2)
        guard let plain = HappierCrypto.secretboxOpen(Data(body.dropFirst(nonceLength)), key: key(kind, machineKey: machineKey),
                                                      nonce: Data(body.prefix(nonceLength))) else {
            return nil
        }
        return try? JSONDecoder().decode(JSONValue.self, from: plain)
    }

    /// Older records without the header: `nonce ‖ secretbox(json)` under the machine key, or under
    /// the recovery secret on legacy accounts (`openAccountScopedBlobCiphertext`'s fallback).
    static func openHeaderless(_ base64: String, keys: [Data]) -> JSONValue? {
        guard let bytes = Base64.decode(base64), bytes.count >= nonceLength + 16 else { return nil }
        for key in keys {
            if let plain = HappierCrypto.secretboxOpen(Data(bytes.dropFirst(nonceLength)), key: key, nonce: Data(bytes.prefix(nonceLength))),
               let value = try? JSONDecoder().decode(JSONValue.self, from: plain) {
                return value
            }
        }
        return nil
    }

    /// `sealAccountScopedBlobCiphertext`: always the current, headed format.
    static func seal(_ value: JSONValue, kind: Kind, machineKey: Data) throws -> String {
        let nonce = HappierCrypto.randomBytes(nonceLength)
        let boxed = try HappierCrypto.secretboxSeal(try value.encoded(), key: key(kind, machineKey: machineKey), nonce: nonce)
        return (Data([magic, kind.rawValue]) + nonce + boxed).base64EncodedString()
    }

    private static func key(_ kind: Kind, machineKey: Data) -> Data {
        let mac = HMAC<SHA512>.authenticationCode(for: Data("happier:account_scoped:\(kind.name):v1".utf8),
                                                   using: SymmetricKey(data: machineKey))
        return Data(mac).prefix(32)
    }
}

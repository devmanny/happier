import CryptoKit
import Foundation

/// Account-scoped records sealed for the account's own devices (`packages/protocol/src/crypto/accountScopedCipher.ts`):
/// `0xA1 ‖ kind ‖ nonce(24) ‖ secretbox(json)`, keyed by HMAC-SHA512(machineKey, "happier:account_scoped:<kind>:v1").
public enum AccountScopedBlob {
    public enum Kind: UInt8, Sendable {
        case providerAccountUsageSnapshot = 6

        var name: String {
            switch self {
            case .providerAccountUsageSnapshot: "provider_account_usage_snapshot"
            }
        }
    }

    private static let magic: UInt8 = 0xA1
    private static let nonceLength = 24

    /// The JSON inside, or nil when it isn't this kind or doesn't open with this key.
    public static func open(_ base64: String, kind: Kind, machineKey: Data) -> JSONValue? {
        guard let bytes = Base64.decode(base64), bytes.count >= 2 + nonceLength + 16,
              bytes[bytes.startIndex] == magic, bytes[bytes.startIndex + 1] == kind.rawValue else { return nil }
        let mac = HMAC<SHA512>.authenticationCode(for: Data("happier:account_scoped:\(kind.name):v1".utf8),
                                                   using: SymmetricKey(data: machineKey))
        let key = Data(mac).prefix(32)
        let body = bytes.dropFirst(2)
        guard let plain = HappierCrypto.secretboxOpen(Data(body.dropFirst(nonceLength)), key: key, nonce: Data(body.prefix(nonceLength))) else {
            return nil
        }
        return try? JSONDecoder().decode(JSONValue.self, from: plain)
    }
}

import CryptoKit
import Foundation

/// The QR a device that isn't signed in shows ("Link with Another Device"):
/// `happier:///account?<box public key, base64url>#supportsCredentialVariants=1`
/// (`auth/pairing/accountConnectUrl.ts`). The signed-in device scans it and approves.
public struct AccountLinkRequest: Equatable, Sendable {
    public let publicKey: Data
    /// The new device opens `HPAC`-tagged responses (data-key and token-only Accounts too).
    public let supportsCredentialVariants: Bool

    public init?(_ link: String) {
        guard let url = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased().hasPrefix("happier") == true,
              url.path == "/account" || (url.host == "account" && (url.path.isEmpty || url.path == "/")),
              let tail = url.percentEncodedQuery?.trimmingCharacters(in: .whitespaces), !tail.isEmpty,
              let key = Base64.decode(tail), key.count == 32
        else { return nil }
        publicKey = key
        supportsCredentialVariants = (url.fragment ?? "").split(separator: "&").contains("supportsCredentialVariants=1")
    }
}

extension Credentials {
    /// This device's credentials sealed for the new device only (`buildAccountLinkResponse.ts`),
    /// opened there by `LinkKeyPair.openLinkResponse`.
    public func accountLinkResponse(for request: AccountLinkRequest) throws -> Data {
        guard request.supportsCredentialVariants else {
            // A released client that only understands the bare 32-byte recovery secret.
            guard case .legacy(_, let secret) = self else { throw AccountKeyProvisioning.OutdatedDevice() }
            return try HappierCrypto.sealBoxBundle(secret, recipientPublicKey: request.publicKey)
        }
        var plaintext = Data("HPAC".utf8)
        switch self {
        case .legacy(_, let secret): plaintext += [0] + secret
        case .dataKey(_, let content): plaintext += [1] + content.publicKey + content.secretKey
        case .tokenOnly: plaintext += [2]
        }
        return try HappierCrypto.sealBoxBundle(plaintext, recipientPublicKey: request.publicKey)
    }
}

/// What the relay publishes about the Account (`GET /v1/user/:id`).
public struct AccountLinkProfile: Equatable, Sendable {
    /// Ed25519 signing key, hex.
    public let publicKey: String?
    /// X25519 content key and its signature by the signing key, standard base64.
    public let contentPublicKey: String?
    public let contentPublicKeySig: String?

    public init(publicKey: String?, contentPublicKey: String?, contentPublicKeySig: String?) {
        self.publicKey = publicKey
        self.contentPublicKey = contentPublicKey
        self.contentPublicKeySig = contentPublicKeySig
    }
}

/// A kept credential is custody, not proof its key is still the Account's: before handing keys to
/// another device, check them against what the relay publishes now
/// (`assertAccountKeyProvisioningAllowed` in `packages/protocol`).
public enum AccountKeyProvisioning {
    public struct Unavailable: LocalizedError {
        public var errorDescription: String? {
            String(localized: "This device's encryption key couldn't be verified as the account's current key. Restore the account here before linking another device.")
        }
    }

    public struct OutdatedDevice: LocalizedError {
        public var errorDescription: String? {
            String(localized: "The other device needs a newer version of Happier to link to this account.")
        }
    }

    private static let contentKeyBinding = Data("Happy content key v1\u{0}".utf8)

    /// The message the signing key signs to publish a content key (`createAccountContentPublicKeyBindingMessage`).
    static func contentKeyBindingMessage(_ contentPublicKey: Data) -> Data {
        contentKeyBinding + contentPublicKey
    }

    public static func verify(encrypted: Bool, account: AccountLinkProfile, credentials: Credentials) throws {
        guard encrypted else { return }
        guard let keys = try? credentials.accountKeys(), let signingHex = account.publicKey,
              let signing = hexData(signingHex) else { throw Unavailable() }
        if account.contentPublicKey != nil || account.contentPublicKeySig != nil {
            guard let content = account.contentPublicKey.flatMap(Base64.decode), content.count == 32,
                  let signature = account.contentPublicKeySig.flatMap(Base64.decode),
                  let signer = try? Curve25519.Signing.PublicKey(rawRepresentation: signing),
                  signer.isValidSignature(signature, for: contentKeyBindingMessage(content)),
                  // The key this device would hand out, derived from its secret, is the published one.
                  (try? HappierCrypto.boxPublicKey(secretKey: keys.content.secretKey)) == content
            else { throw Unavailable() }
            return
        }
        // Accounts from before published content keys: the recovery secret itself proves the
        // unchanged signing identity.
        guard keys.signingPublicKey == signing else { throw Unavailable() }
    }

    private static func hexData(_ hex: String) -> Data? {
        let chars = Array(hex.lowercased())
        guard chars.count % 2 == 0 else { return nil }
        var data = Data(capacity: chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            data.append(byte)
        }
        return data
    }
}

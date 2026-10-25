import Foundation

/// Ephemeral box keypair a new device uses to receive account credentials from an
/// already-signed-in device (`RestoreQrView.tsx`, `buildAccountLinkResponse.ts`).
public struct LinkKeyPair: Sendable {
    public struct InvalidResponse: Error {}

    public let publicKey: Data
    let secretKey: Data

    public static func generate() throws -> LinkKeyPair {
        let secret = HappierCrypto.boxSecretKey(fromSeed: HappierCrypto.randomBytes(32))
        return LinkKeyPair(publicKey: try HappierCrypto.boxPublicKey(secretKey: secret), secretKey: secret)
    }

    /// QR content shown on the new device and scanned by a signed-in device.
    public var accountLinkURL: String {
        "happier:///account?\(Base64.urlEncoded(publicKey))#supportsCredentialVariants=1"
    }

    /// Opens the v2 `tokenEncrypted` field (box bundle of the UTF-8 token).
    public func openToken(_ base64: String) throws -> String {
        guard let sealed = Base64.decode(base64),
              let plain = HappierCrypto.openBoxBundle(sealed, secretKey: secretKey),
              let token = String(data: plain, encoding: .utf8)
        else { throw InvalidResponse() }
        return token
    }

    /// Opens the approving device's `response`: a bare 32-byte secret, or `HPAC ‖ tag ‖ keys`.
    public func openLinkResponse(_ base64: String, token: String) throws -> Credentials {
        guard let sealed = Base64.decode(base64),
              let plain = HappierCrypto.openBoxBundle(sealed, secretKey: secretKey)
        else { throw InvalidResponse() }
        if plain.count == 32 { return .legacy(token: token, secret: plain) }
        guard plain.count >= 5, plain.prefix(4) == Data("HPAC".utf8) else { throw InvalidResponse() }
        let body = Data(plain.dropFirst(5))
        switch plain[plain.startIndex + 4] {
        case 0 where body.count == 32:
            return .legacy(token: token, secret: body)
        case 1 where body.count == 64:
            return .dataKey(token: token, content: ContentKeyPair(publicKey: body.prefix(32), secretKey: body.suffix(32)))
        case 2 where body.isEmpty:
            return .tokenOnly(token: token)
        default:
            throw InvalidResponse()
        }
    }
}

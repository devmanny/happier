import CryptoKit
import Foundation
import Testing
@testable import HappierKit

/// The signed-in side of "Link with Another Device": read the new device's QR, check this device
/// still holds the Account's current key, and seal the credentials only that device can open.
struct AccountLinkApprovalTests {
    @Test func readsTheQRANewDeviceShows() throws {
        let pair = try LinkKeyPair.generate()
        let request = try #require(AccountLinkRequest(pair.accountLinkURL))
        #expect(request.publicKey == pair.publicKey)
        #expect(request.supportsCredentialVariants)

        let old = try #require(AccountLinkRequest("happier://account?\(Base64.urlEncoded(pair.publicKey))"))
        #expect(!old.supportsCredentialVariants)
        #expect(AccountLinkRequest("happier:///pair?v=1&pairId=x") == nil)
        #expect(AccountLinkRequest("https://example.com/account?abc") == nil)
        #expect(AccountLinkRequest("happier:///account?") == nil)
    }

    @Test func theNewDeviceOpensEveryCredentialShape() throws {
        let pair = try LinkKeyPair.generate()
        let request = try #require(AccountLinkRequest(pair.accountLinkURL))
        let secret = HappierCrypto.randomBytes(32)
        let content = AccountKeys(content: try AccountKeys(masterSecret: HappierCrypto.randomBytes(32)).content).content
        for credentials in [Credentials.legacy(token: "t", secret: secret), .dataKey(token: "t", content: content), .tokenOnly(token: "t")] {
            let sealed = try credentials.accountLinkResponse(for: request)
            #expect(try pair.openLinkResponse(sealed.base64EncodedString(), token: "t") == credentials)
        }
    }

    @Test func aDeviceWithoutCredentialVariantsOnlyGetsALegacySecret() throws {
        let pair = try LinkKeyPair.generate()
        let request = try #require(AccountLinkRequest("happier:///account?\(Base64.urlEncoded(pair.publicKey))"))
        let secret = HappierCrypto.randomBytes(32)
        let sealed = try Credentials.legacy(token: "t", secret: secret).accountLinkResponse(for: request)
        #expect(HappierCrypto.openBoxBundle(sealed, secretKey: pair.secretKey) == secret)
        let content = try AccountKeys(masterSecret: secret).content
        #expect(throws: (any Error).self) { try Credentials.dataKey(token: "t", content: content).accountLinkResponse(for: request) }
    }

    @Test func aLegacyAccountMustStillBeSignedByThisSecret() throws {
        let secret = HappierCrypto.randomBytes(32)
        let signing = try #require(try AccountKeys(masterSecret: secret).signingPublicKey)
        let hex = signing.map { String(format: "%02x", $0) }.joined()
        let mine = AccountLinkProfile(publicKey: hex.uppercased(), contentPublicKey: nil, contentPublicKeySig: nil)
        try AccountKeyProvisioning.verify(encrypted: true, account: mine, credentials: .legacy(token: "t", secret: secret))

        let someoneElse = AccountLinkProfile(publicKey: String(repeating: "ab", count: 32), contentPublicKey: nil, contentPublicKeySig: nil)
        #expect(throws: AccountKeyProvisioning.Unavailable.self) {
            try AccountKeyProvisioning.verify(encrypted: true, account: someoneElse, credentials: .legacy(token: "t", secret: secret))
        }
        // Without key material there is nothing to vouch for, except on a plaintext Account.
        #expect(throws: AccountKeyProvisioning.Unavailable.self) {
            try AccountKeyProvisioning.verify(encrypted: true, account: mine, credentials: .tokenOnly(token: "t"))
        }
        try AccountKeyProvisioning.verify(encrypted: false, account: someoneElse, credentials: .tokenOnly(token: "t"))
    }

    @Test func aPublishedContentKeyMustBeSignedAndMatchThisDevice() throws {
        let secret = HappierCrypto.randomBytes(32)
        let keys = try AccountKeys(masterSecret: secret)
        let hex = try #require(keys.signingPublicKey).map { String(format: "%02x", $0) }.joined()
        let message = Data("Happy content key v1\u{0}".utf8) + keys.content.publicKey
        let signature = try keys.sign(message)
        let published = AccountLinkProfile(publicKey: hex, contentPublicKey: keys.content.publicKey.base64EncodedString(),
                                           contentPublicKeySig: signature.base64EncodedString())
        try AccountKeyProvisioning.verify(encrypted: true, account: published, credentials: .legacy(token: "t", secret: secret))
        try AccountKeyProvisioning.verify(encrypted: true, account: published, credentials: .dataKey(token: "t", content: keys.content))

        // A rotated key on the relay: this device's copy is stale and must not be handed out.
        let stale = try AccountKeys(masterSecret: HappierCrypto.randomBytes(32)).content
        #expect(throws: AccountKeyProvisioning.Unavailable.self) {
            try AccountKeyProvisioning.verify(encrypted: true, account: published, credentials: .dataKey(token: "t", content: stale))
        }
        var forged = signature
        forged[0] ^= 0xFF
        let unsigned = AccountLinkProfile(publicKey: hex, contentPublicKey: published.contentPublicKey, contentPublicKeySig: forged.base64EncodedString())
        #expect(throws: AccountKeyProvisioning.Unavailable.self) {
            try AccountKeyProvisioning.verify(encrypted: true, account: unsigned, credentials: .legacy(token: "t", secret: secret))
        }
    }
}

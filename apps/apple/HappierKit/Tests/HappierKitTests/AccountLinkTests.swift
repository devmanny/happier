import Foundation
import Testing
@testable import HappierKit

/// Mirrors `apps/ui/sources/auth/flows/buildAccountLinkResponse.ts`: the approving device seals
/// either a bare 32-byte secret or `HPAC ‖ tag ‖ keys` to the new device's box public key.
@Suite struct AccountLinkTests {
    let device = try! LinkKeyPair.generate()

    private func seal(_ plaintext: Data) throws -> String {
        try HappierCrypto.sealBoxBundle(plaintext, recipientPublicKey: device.publicKey).base64EncodedString()
    }

    @Test func bareSecretBecomesLegacyCredentials() throws {
        let secret = Data(repeating: 7, count: 32)
        let credentials = try device.openLinkResponse(seal(secret), token: "tok")
        #expect(credentials == .legacy(token: "tok", secret: secret))
    }

    @Test func taggedVariantsDecode() throws {
        let magic = Data("HPAC".utf8)
        let secret = Data(repeating: 1, count: 32)
        #expect(try device.openLinkResponse(seal(magic + [0] + secret), token: "t") == .legacy(token: "t", secret: secret))

        let pub = Data(repeating: 2, count: 32), machineKey = Data(repeating: 3, count: 32)
        #expect(try device.openLinkResponse(seal(magic + [1] + pub + machineKey), token: "t")
            == .dataKey(token: "t", content: ContentKeyPair(publicKey: pub, secretKey: machineKey)))

        #expect(try device.openLinkResponse(seal(magic + [2]), token: "t") == .tokenOnly(token: "t"))
    }

    @Test func rejectsUnknownPayloads() throws {
        #expect(throws: (any Error).self) { try device.openLinkResponse(seal(Data("HPAC".utf8) + [9]), token: "t") }
        #expect(throws: (any Error).self) { try device.openLinkResponse(seal(Data(repeating: 1, count: 31)), token: "t") }
    }

    @Test func linkURLCarriesBase64URLPublicKey() {
        let url = device.accountLinkURL
        #expect(url.hasPrefix("happier:///account?"))
        #expect(url.hasSuffix("#supportsCredentialVariants=1"))
        let key = url.dropFirst("happier:///account?".count).prefix { $0 != "#" }
        #expect(!key.contains("+") && !key.contains("/") && !key.contains("="))
        #expect(Base64.decode(String(key)) == device.publicKey)
    }

    @Test func tokenEncryptedIsOpenedWithDeviceKey() throws {
        let sealed = try HappierCrypto.sealBoxBundle(Data("jwt.token".utf8), recipientPublicKey: device.publicKey)
        #expect(try device.openToken(sealed.base64EncodedString()) == "jwt.token")
    }
}

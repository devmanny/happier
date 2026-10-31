import CryptoKit
import Foundation
import Testing
@testable import HappierKit

/// Creating an account with a new device key (`index.tsx` `createAccount`, `getToken.ts`,
/// `/v1/features` auth capabilities, `accountKeyProvisioning.ts`).
@Suite struct AccountCreationTests {
    /// The shape `happier.nomada.cloud` serves: device-key sign-up on, GitHub configured off.
    static let relayFeatures: JSONValue = [
        "features": ["auth": ["login": ["keyChallenge": ["enabled": true]]], "sharing": ["contentKeys": ["enabled": true]]],
        "capabilities": ["auth": [
            "methods": [
                ["id": "key_challenge", "actions": [["id": "login", "enabled": true, "mode": "keyed"], ["id": "provision", "enabled": true, "mode": "keyed"]]],
                ["id": "github", "actions": [["id": "provision", "enabled": false, "mode": "keyed"]]],
            ],
            "signup": ["methods": [["id": "anonymous", "enabled": true]]],
        ]],
    ]

    @Test func readsWhetherTheRelayLetsANewDeviceKeySignUp() {
        let options = AuthOptions(features: Self.relayFeatures)
        #expect(options.canCreateAccount && options.publishesContentKey)

        let closed: JSONValue = ["capabilities": ["auth": ["methods": [
            ["id": "key_challenge", "actions": [["id": "login", "enabled": true, "mode": "keyed"], ["id": "provision", "enabled": false, "mode": "keyed"]]],
        ]]]]
        #expect(!AuthOptions(features: closed).canCreateAccount)
        // Older relays list sign-up methods only.
        #expect(!AuthOptions(features: ["capabilities": ["auth": ["signup": ["methods": [["id": "anonymous", "enabled": false]]]]]]).canCreateAccount)
        // Relays from before auth capabilities allowed anonymous sign-up.
        #expect(AuthOptions(features: [:]).canCreateAccount && !AuthOptions(features: [:]).publishesContentKey)
        #expect(!AuthOptions(features: ["features": ["auth": ["login": ["keyChallenge": ["enabled": false]]]]]).canCreateAccount)
    }

    @Test func theChallengeProvesTheKeyAndCanPublishTheSignedContentKey() throws {
        let keys = try AccountKeys(masterSecret: Data(0..<32))
        let challenge = Data(repeating: 9, count: 32)
        let plain = try AuthAPI.challengeBody(keys: keys, challenge: challenge, publishContentKey: false)
        #expect(plain["contentPublicKey"] == nil)
        let body = try AuthAPI.challengeBody(keys: keys, challenge: challenge, publishContentKey: true)
        let signing = try Curve25519.Signing.PublicKey(rawRepresentation: try #require(body["publicKey"]?.stringValue.flatMap(Base64.decode)))
        #expect(signing.rawRepresentation == keys.signingPublicKey)
        #expect(signing.isValidSignature(try #require(body["signature"]?.stringValue.flatMap(Base64.decode)), for: challenge))
        #expect(body["challenge"]?.stringValue == challenge.base64EncodedString())

        // What this device publishes is what another device checks before linking.
        let profile = AccountLinkProfile(publicKey: keys.signingPublicKey!.map { String(format: "%02x", $0) }.joined(),
                                         contentPublicKey: body["contentPublicKey"]?.stringValue,
                                         contentPublicKeySig: body["contentPublicKeySig"]?.stringValue)
        #expect(body["contentPublicKey"]?.stringValue == keys.content.publicKey.base64EncodedString())
        try AccountKeyProvisioning.verify(encrypted: true, account: profile, credentials: .legacy(token: "t", secret: Data(0..<32)))
    }
}

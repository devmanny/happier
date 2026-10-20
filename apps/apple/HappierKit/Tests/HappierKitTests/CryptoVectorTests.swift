import Foundation
import Testing
@testable import HappierKit

// Golden vectors are copied verbatim from the TypeScript sources so the Swift client stays
// wire-compatible with the UI and CLI:
//   apps/ui/sources/encryption/deriveKey.appspec.ts
//   packages/protocol/src/crypto/cryptoGoldenVectors.ts
//   apps/ui/sources/sync/encryption/nativeCryptoWorker/cryptoGoldenVectors.ts

private func hex(_ s: String) -> Data {
    var data = Data()
    var index = s.startIndex
    while index < s.endIndex {
        let next = s.index(index, offsetBy: 2)
        data.append(UInt8(s[index..<next], radix: 16)!)
        index = next
    }
    return data
}

private func repeated(_ byte: UInt8, _ count: Int = 32) -> Data { Data(repeating: byte, count: count) }

/// Mirrors the TS deterministic RNG used by the golden vectors (emits 1, 2, 3, ...).
private final class CountingRandom: @unchecked Sendable {
    var next: UInt8 = 1
    func bytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in defer { next &+= 1 }; return next })
    }
}

@Suite struct KeyDerivationTests {
    @Test func derivesTreeLikeTheTypeScriptImplementation() {
        let key = HappierCrypto.deriveKey(master: Data("test seed".utf8), usage: "test usage", path: ["child1", "child2"])
        #expect(key == hex("1011C097D2105D27362B987A631496BBF68B836124D1D072E9D1613C6028CF75"))
    }

    @Test func derivesAccountKeysFromMasterSecret() throws {
        let master = Data(0..<32)
        let account = try AccountKeys(masterSecret: master)
        #expect(account.signingPublicKey == hex("03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"))
        #expect(account.content.secretKey == hex("56f43aee0c93b2163b5e45b14264d06b0c9613195e23da0190f6838d6ac9c562"))
        #expect(account.content.publicKey == hex("241af979415ad6dbc99d93af8c2babf288cf96084ad6e8fe7072ed4e229d445b"))
    }
}

@Suite struct BoxBundleTests {
    @Test func sealsDeterministicallyLikeGoldenVector() throws {
        let rng = CountingRandom()
        let bundle = try HappierCrypto.sealBoxBundle(
            repeated(0x03), recipientPublicKey: hex("57db4b359f23ae5e146e4e2512056704722506348c150c14753d0c933d04d421"),
            random: rng.bytes)
        #expect(bundle == hex("07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c2122232425262728292a2b2c2d2e2f30313233343536373859c1c234f45efd03c1ab22b9b03f8b3feb1276a05a7868f0c6a9c8bfcd0423033d6aea6e047523bc7413ee42040d1677"))
    }

    @Test func opensDirectSecretAndSeedCompatibleSecret() throws {
        let direct = hex("07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c2122232425262728292a2b2c2d2e2f30313233343536373859c1c234f45efd03c1ab22b9b03f8b3feb1276a05a7868f0c6a9c8bfcd0423033d6aea6e047523bc7413ee42040d1677")
        #expect(HappierCrypto.openBoxBundle(direct, secretKey: repeated(0x09)) == repeated(0x03))

        let seeded = hex("07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c2122232425262728292a2b2c2d2e2f303132333435363738f427df224168af852aee33ba83373277a78e69b82653cae4c31bf92707cc7d03dfd549ca06b072d61318b94ad3ff8c80")
        #expect(HappierCrypto.openBoxBundle(seeded, secretKey: repeated(0x0b)) == repeated(0x07))
    }

    @Test func opensDataKeyEnvelopesAndRejectsMalformedOnes() {
        let direct = hex("0007a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c2122232425262728292a2b2c2d2e2f3031323334353637387c08c8f85db24be438ff0be65a8f9599ec1571a75d7f6ff7c1aecfb8ca0324043a6ded69037224bb7314e945030a1170")
        #expect(HappierCrypto.openDataKeyEnvelope(direct, secretKey: repeated(0x09)) == repeated(0x04))
        let seeded = hex("0007a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c2122232425262728292a2b2c2d2e2f3031323334353637387e1905a028d044ade8c2bec4c04b6973a1886fbe2055cce2c51dff2101ca7b05d9d34fcc00b674d0151ebf4cd5f98a86")
        #expect(HappierCrypto.openDataKeyEnvelope(seeded, secretKey: repeated(0x0b)) == repeated(0x01))
        #expect(HappierCrypto.openDataKeyEnvelope(hex("000102"), secretKey: repeated(0x09)) == nil)
        #expect(HappierCrypto.openDataKeyEnvelope(hex("630102"), secretKey: repeated(0x09)) == nil)
        #expect(HappierCrypto.openBoxBundle(hex("010203"), secretKey: repeated(0x09)) == nil)
    }
}

@Suite struct ContentCipherTests {
    let aesWire = hex("000102030405060708090a0b0cf1211e9915dd5068a37d3aa5eeffe6b4e0a675417d5c052fafd461661c36dd0cf1f2b1a76b8e3174bbcb8a675c3cbdcfa2406b41a3adc39f41fc6676ff3344e5475fca3985ed10e738b26e68aa7472efe7d3425417")
    let secretboxWire = hex("0102030405060708090a0b0c0d0e0f101112131415161718a7f9dbcf4dfdb4c1c924db8bace89fe9bb153ce1d84a2dd0577b0180665a535624695cc2a522842454646c5aff339f9856c16f1fc54a8dade256abb7cd4538625d88be1f8b915d1d7891965c33d98bc6f493a5ed52")

    @Test func aesGcmMatchesGoldenWire() throws {
        let cipher = ContentCipher.aesGCM(key: repeated(0x0d))
        let sealed = try cipher.encrypt("hello", nonce: hex("0102030405060708090a0b0c"))
        #expect(sealed == aesWire)
        #expect(try cipher.decrypt(aesWire) == "hello")
    }

    @Test func secretboxMatchesGoldenWire() throws {
        let cipher = ContentCipher.secretbox(key: repeated(0x0c))
        let sealed = try cipher.encrypt("hello", nonce: hex("0102030405060708090a0b0c0d0e0f101112131415161718"))
        #expect(sealed == secretboxWire)
        #expect(try cipher.decrypt(secretboxWire) == "hello")
    }

    @Test func readsBareJsonWithoutSerializationWrapper() throws {
        let cipher = ContentCipher.aesGCM(key: repeated(0x0d))
        let bare = try cipher.seal(Data(#"{"role":"user"}"#.utf8), nonce: hex("0102030405060708090a0b0c"))
        #expect(try cipher.decrypt(bare) == ["role": "user"])
    }

    @Test func rejectsWrongKeyAndUnknownVersion() {
        #expect(throws: (any Error).self) { try ContentCipher.aesGCM(key: repeated(0x0e)).decrypt(aesWire) }
        var badVersion = aesWire
        badVersion[0] = 1
        #expect(throws: (any Error).self) { try ContentCipher.aesGCM(key: repeated(0x0d)).decrypt(badVersion) }
    }
}

@Suite struct SecretKeyFormatTests {
    let master = Data(0..<32)

    @Test func formatsAndParsesBackupKey() throws {
        #expect(SecretKeyFormat.format(master) == "AAAQE-AYEAU-DAOCA-JBIFQ-YDIOB-4IBCE-QTCQK-RMFYY-DENBW-HA5DY-PQ")
        #expect(try SecretKeyFormat.parse("aaaqe-ayeau-daoca-jbifq-ydiob-4ibce-qtcqk-rmfyy-denbw-ha5dy-pq") == master)
        #expect(try SecretKeyFormat.parse("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8") == master)
    }

    @Test func rejectsWrongLength() {
        #expect(throws: (any Error).self) { try SecretKeyFormat.parse("AAAQE-AYEAU") }
    }
}

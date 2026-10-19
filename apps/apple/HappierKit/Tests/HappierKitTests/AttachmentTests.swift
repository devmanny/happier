import CryptoKit
import Foundation
import Testing
@testable import HappierKit

/// Session attachment uploads (`transferChunkEncryption.ts`, `uploadAttachmentDraftsToSession.ts`,
/// `buildAttachmentMessageMeta.ts`).
@Suite struct AttachmentTests {
    @Test func chunkDecryptsWithRecipientKeyAndIsBoundToItsPosition() throws {
        let recipientSecret = Data(repeating: 5, count: 32)
        let recipientPublic = try HappierCrypto.boxPublicKey(secretKey: HappierCrypto.boxSecretKey(fromSeed: recipientSecret))
        let payload = Data("hello attachment".utf8)
        let chunk = try TransferChunk.encrypt(payload, uploadId: "up-1", index: 3, recipientPublicKeyBase64: recipientPublic.base64EncodedString())

        // What the CLI does: open the data key, then AES-GCM with AAD "0:<uploadId>:<index>".
        func open(uploadId: String, index: Int) throws -> Data {
            let envelope = try #require(Data(base64Encoded: chunk.encryptedDataKeyEnvelopeBase64))
            let dataKey = try #require(HappierCrypto.openDataKeyEnvelope(envelope, secretKey: recipientSecret))
            let bytes = try #require(Data(base64Encoded: chunk.payloadBase64))
            #expect(bytes.first == 0)
            let box = try AES.GCM.SealedBox(combined: bytes.dropFirst())
            return try AES.GCM.open(box, using: SymmetricKey(data: dataKey), authenticating: Data("0:\(uploadId):\(index)".utf8))
        }
        #expect(try open(uploadId: "up-1", index: 3) == payload)
        #expect(throws: (any Error).self) { try open(uploadId: "up-1", index: 4) }
    }

    @Test func messageCarriesAttachmentBlockDisplayTextAndStructuredImages() {
        let image = UploadedAttachment(name: "IMG_1.png", path: ".happier/uploads/messages/L/a-IMG_1.png", mimeType: "image/png", sizeBytes: 10, sha256: "abc")
        let doc = UploadedAttachment(name: "spec.pdf", path: ".happier/uploads/messages/L/b-spec.pdf", mimeType: "application/pdf", sizeBytes: 20, sha256: "def")
        let message = AttachmentMessage(text: "look at these", attachments: [image, doc])
        #expect(message.text == """
        look at these

        Attachments: open and analyze these files before answering.
        [attachments]
        - .happier/uploads/messages/L/a-IMG_1.png (IMG_1.png, image/png, 10 bytes)
        - .happier/uploads/messages/L/b-spec.pdf (spec.pdf, application/pdf, 20 bytes)
        [/attachments]
        """)
        #expect(message.meta["displayText"] == "look at these")
        #expect(message.meta["happier"]?["kind"] == "attachments.v1")
        #expect(message.meta["happier"]?["payload"]?["attachments"]?.arrayValue?.count == 2)
        let structured = message.meta["happierStructuredInputV1"]
        #expect(structured?["v"] == 1)
        #expect(structured?["attachments"] == [[
            "type": "localImage", "kind": "image", "localPath": .string(image.path), "path": .string(image.path),
            "provenance": ["kind": "sessionAttachmentUpload"], "name": "IMG_1.png", "mimeType": "image/png",
            "sizeBytes": 10, "sha256": "abc",
        ]])
    }

    @Test func transcriptShowsAttachmentNamesUnderDisplayText() {
        let message = AttachmentMessage(text: "mira", attachments: [UploadedAttachment(name: "a.png", path: "p", mimeType: "image/png", sizeBytes: 1, sha256: "x")])
        var transcript = Transcript()
        transcript.apply([TranscriptMessage(id: "m", seq: 1, localId: "L", createdAt: .now, record: [
            "role": "user", "content": ["type": "text", "text": .string(message.text)], "meta": .object(message.meta)])])
        guard case .userText(let user)? = transcript.items.first else { Issue.record("no user item"); return }
        #expect(user.text == "mira")
        #expect(user.attachments == ["a.png"])
    }
}

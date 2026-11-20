import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HappierKit

@Suite struct AttachmentPreviewTests {
    @Test func aDownloadedChunkOpensWithTheTransferKey() throws {
        let seed = Data(repeating: 7, count: 32)
        let keys = try TransferRecipient(seed: seed)
        let payload = Data("bytes from the computer".utf8)
        // What the daemon sends: the same chunk format as uploads, sealed to our temporary key.
        let chunk = try TransferChunk.encrypt(payload, uploadId: "dl-1", index: 2, recipientPublicKeyBase64: keys.publicKeyBase64)
        #expect(try TransferChunk.decrypt(payloadBase64: chunk.payloadBase64, encryptedDataKeyEnvelopeBase64: chunk.encryptedDataKeyEnvelopeBase64,
                                          transferId: "dl-1", index: 2, recipient: keys) == payload)
        #expect(throws: (any Error).self) {
            try TransferChunk.decrypt(payloadBase64: chunk.payloadBase64, encryptedDataKeyEnvelopeBase64: chunk.encryptedDataKeyEnvelopeBase64,
                                      transferId: "dl-1", index: 3, recipient: keys)
        }
    }

    private func png(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func imagesShrinkToASmallJPEG() async throws {
        let thumbnail = try #require(await AttachmentThumbnail.make(data: try png(width: 1200, height: 800), mimeType: "image/png"))
        #expect(max(thumbnail.width, thumbnail.height) == AttachmentThumbnail.maxSide)
        #expect(thumbnail.width == 320 && thumbnail.height == 213)
        #expect(thumbnail.jpeg.count < 40_000)
        #expect(thumbnail.durationSeconds == nil)
        #expect(CGImageSourceCreateWithData(thumbnail.jpeg as CFData, nil).flatMap { CGImageSourceGetType($0) } as String? == UTType.jpeg.identifier)
    }

    @Test func messagesCarryPreviewsThatReadBack() throws {
        let photo = UploadedAttachment(name: "a.jpg", path: ".happier/uploads/messages/L/a.jpg", mimeType: "image/jpeg", sizeBytes: 900_000, sha256: "s1")
        let clip = UploadedAttachment(name: "b.mov", path: ".happier/uploads/messages/L/b.mov", mimeType: "video/quicktime", sizeBytes: 9_000_000, sha256: nil)
        let thumbnail = AttachmentThumbnail(jpeg: Data([1, 2, 3]), width: 320, height: 240, durationSeconds: nil)
        let poster = AttachmentThumbnail(jpeg: Data([4, 5]), width: 180, height: 320, durationSeconds: 12.5)
        let message = AttachmentMessage(text: "mira", attachments: [photo, clip], thumbnails: [photo.path: thumbnail, clip.path: poster])
        let record: JSONValue = ["role": "user", "content": ["type": "text", "text": .string(message.text)], "meta": .object(message.meta)]

        var transcript = Transcript()
        transcript.apply([TranscriptMessage(id: "m", seq: 1, localId: nil, createdAt: .now, record: record)])
        guard case .userText(let user)? = transcript.items.first else { Issue.record("no user message"); return }
        #expect(user.text == "mira")
        #expect(user.files.map(\.name) == ["a.jpg", "b.mov"])
        #expect(user.files[0].thumbnail == thumbnail && user.files[0].sizeBytes == 900_000 && user.files[0].sha256 == "s1")
        #expect(user.files[1].thumbnail == poster && user.files[1].isVideo)
        #expect(user.attachments == ["a.jpg", "b.mov"])
    }
}

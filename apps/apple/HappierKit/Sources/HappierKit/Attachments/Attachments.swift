import CryptoKit
import Foundation

/// One encrypted upload chunk (`transferChunkEncryption.ts`): a fresh data key per chunk,
/// AES-256-GCM with AAD `"0:<uploadId>:<index>"`, the key sealed to the daemon's recipient key.
public enum TransferChunk {
    public struct Encrypted: Sendable {
        public let payloadBase64: String
        public let encryptedDataKeyEnvelopeBase64: String
    }

    public static func encrypt(_ payload: Data, uploadId: String, index: Int, recipientPublicKeyBase64: String,
                               random: (Int) -> Data = HappierCrypto.randomBytes) throws -> Encrypted {
        guard let recipient = Data(base64Encoded: recipientPublicKeyBase64), recipient.count == 32 else {
            throw HappierCrypto.Failure.invalidLength
        }
        let dataKey = random(32)
        let nonce = try AES.GCM.Nonce(data: random(12))
        let sealed = try AES.GCM.seal(payload, using: SymmetricKey(data: dataKey), nonce: nonce,
                                      authenticating: Data("0:\(uploadId):\(index)".utf8))
        let envelope = try HappierCrypto.sealDataKeyEnvelope(dataKey, recipientPublicKey: recipient)
        return Encrypted(payloadBase64: (Data([0]) + sealed.combined!).base64EncodedString(),
                         encryptedDataKeyEnvelopeBase64: envelope.base64EncodedString())
    }
}

/// A file picked in the composer, not yet uploaded.
public struct AttachmentDraft: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let name: String
    public let mimeType: String?
    public let data: Data

    public init(name: String, mimeType: String?, data: Data) {
        self.name = name
        self.mimeType = mimeType
        self.data = data
    }

    public var isImage: Bool { mimeType?.lowercased().hasPrefix("image/") ?? false }
}

/// A file the daemon stored for a message (`daemon.bulkTransfer.upload.finalize`).
public struct UploadedAttachment: Sendable, Equatable {
    public let name: String
    public let path: String
    public let mimeType: String?
    public let sizeBytes: Int
    public let sha256: String?

    public init(name: String, path: String, mimeType: String?, sizeBytes: Int, sha256: String?) {
        self.name = name
        self.path = path
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }

    var isImage: Bool { mimeType?.lowercased().hasPrefix("image/") ?? false }
}

/// User message text + meta for uploaded attachments (`formatAttachmentsBlock`,
/// `buildAttachmentMessageMeta`): the agent reads the paths from the text block, the UI shows
/// `displayText`, and images are also offered as structured local-image input.
public struct AttachmentMessage: Sendable {
    public let text: String
    public let meta: [String: JSONValue]

    public init(text userText: String, attachments: [UploadedAttachment]) {
        var lines = ["Attachments: open and analyze these files before answering.", "[attachments]"]
        for a in attachments {
            lines.append("- \(a.path) (\(a.name), \(a.mimeType ?? "unknown"), \(a.sizeBytes) bytes)")
        }
        lines.append("[/attachments]")
        let block = lines.joined(separator: "\n")
        text = userText.isEmpty ? block : userText + "\n\n" + block

        var meta: [String: JSONValue] = [
            "displayText": .string(userText),
            "happier": ["kind": "attachments.v1", "payload": ["attachments": .array(attachments.map { a in
                var o: [String: JSONValue] = ["name": .string(a.name), "path": .string(a.path), "sizeBytes": .number(Double(a.sizeBytes))]
                if let m = a.mimeType { o["mimeType"] = .string(m) }
                if let s = a.sha256 { o["sha256"] = .string(s) }
                return .object(o)
            })]],
        ]
        let images: [JSONValue] = attachments.filter(\.isImage).map { a in
            var o: [String: JSONValue] = [
                "type": "localImage", "kind": "image", "localPath": .string(a.path), "path": .string(a.path),
                "provenance": ["kind": "sessionAttachmentUpload"], "name": .string(a.name), "sizeBytes": .number(Double(a.sizeBytes)),
            ]
            if let m = a.mimeType { o["mimeType"] = .string(m) }
            if let s = a.sha256 { o["sha256"] = .string(s) }
            return .object(o)
        }
        if !images.isEmpty { meta["happierStructuredInputV1"] = ["v": 1, "attachments": .array(images)] }
        self.meta = meta
    }
}

/// Bytes sent so far for one message's attachments, as a 0…1 fraction for the sending bubble.
public struct UploadProgress: Equatable, Sendable {
    public let totalBytes: Int
    public private(set) var sentBytes = 0

    public init(totalBytes: Int) {
        self.totalBytes = totalBytes
    }

    public mutating func add(_ bytes: Int) {
        sentBytes = min(totalBytes, sentBytes + bytes)
    }

    public var fraction: Double {
        totalBytes > 0 ? Double(sentBytes) / Double(totalBytes) : 1
    }

    /// Bytes-weighted progress of several uploads (one session can send more than one message).
    public static func combinedFraction(_ uploads: [UploadProgress]) -> Double {
        let total = uploads.reduce(0) { $0 + $1.totalBytes }
        return total > 0 ? Double(uploads.reduce(0) { $0 + $1.sentBytes }) / Double(total) : 1
    }
}

/// Lets the app keep attachment uploads running while it is in the background.
@MainActor
public protocol UploadObserver: AnyObject {
    func uploadDidStart(localId: String, sessionTitle: String, fileCount: Int)
    func uploadDidProgress(localId: String, fraction: Double)
    func uploadDidFinish(localId: String, success: Bool)
}

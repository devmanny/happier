import Foundation
import os

/// Owns a local send until the server acknowledges it. Its network closures are the existing
/// daemon RPC and server pending-queue boundaries, shared by the first attempt and manual retry.
@MainActor
final class OutgoingSend {
    typealias RPC = @MainActor (String, JSONValue) async throws -> JSONValue
    typealias Enqueue = @MainActor (String, JSONValue, PendingAction) async throws -> Void

    let localId: String
    let sessionId: String
    let text: String
    let attachments: [AttachmentDraft]
    var isCancelled = false
    var isSending = false
    private var isAcknowledged = false

    private let log = Logger(subsystem: "dev.happier.apple", category: "uploads")
    private var uploaded: [UploadedAttachment] = []
    private var thumbnails: [String: AttachmentThumbnail] = [:]
    /// Pending-queue retries require the exact ciphertext and requested action, even if session
    /// activity or composer controls changed after the server accepted a request with a lost ACK.
    private var prepared: (content: JSONValue, action: PendingAction)?

    init(localId: String = UUID().uuidString.lowercased(), sessionId: String, text: String, attachments: [AttachmentDraft]) {
        self.localId = localId
        self.sessionId = sessionId
        self.text = text
        self.attachments = attachments
    }

    /// The canonical transcript is also a delivery acknowledgement when the HTTP ACK was lost.
    @discardableResult
    func acknowledge(_ message: TranscriptMessage) -> Bool {
        guard message.localId == localId, message.record["role"]?.stringValue == "user" else { return false }
        isAcknowledged = true
        return true
    }

    func deliver(context: () throws -> (Session, [String: JSONValue]), rpc: RPC, enqueue: Enqueue,
                 progress: (Int) -> Void) async throws {
        try checkCancellation()
        progress(attachments.prefix(uploaded.count).reduce(0) { $0 + $1.data.count })
        if let prepared {
            try await submit(prepared.content, action: prepared.action, via: enqueue)
            return
        }
        for draft in attachments.dropFirst(uploaded.count) {
            try checkCancellation()
            let thumbnail = await AttachmentThumbnail.make(data: draft.data, mimeType: draft.mimeType)
            try checkCancellation()
            let file = try await upload(draft, rpc: rpc, progress: progress)
            uploaded.append(file)
            thumbnails[file.path] = thumbnail
        }
        let (session, initialMeta) = try context()
        var meta = initialMeta
        var body = text
        if !uploaded.isEmpty {
            let message = AttachmentMessage(text: text, attachments: uploaded, thumbnails: thumbnails)
            body = message.text
            meta.merge(message.meta) { $1 }
        }
        let record: JSONValue = ["role": "user", "content": ["type": "text", "text": .string(body)], "meta": .object(meta)]
        let content: JSONValue = session.isPlain ? ["t": "plain", "v": record] : .string(try session.encodeDocument(record))
        let action = SendDecision.action(for: text, session: session)
        prepared = (content, action)
        try await submit(content, action: action, via: enqueue)
    }

    private func submit(_ content: JSONValue, action: PendingAction, via enqueue: Enqueue) async throws {
        try checkCancellation()
        do { try await enqueue(localId, content, action) } catch {
            // A matching canonical row proves delivery even if the request's response was lost.
            if !isAcknowledged { throw error }
        }
    }

    private func checkCancellation() throws {
        if isCancelled { throw CancellationError() }
        try Task.checkCancellation()
    }

    /// Uploads one file to the session's machine through the daemon's bulk-transfer RPCs
    /// (`daemonSessionAttachments.ts`); the daemon applies its default attachment location.
    private func upload(_ draft: AttachmentDraft, rpc: RPC, progress: (Int) -> Void) async throws -> UploadedAttachment {
        guard draft.data.count <= HappierStore.maxAttachmentBytes else {
            let limit = ByteCountFormatter.string(fromByteCount: Int64(HappierStore.maxAttachmentBytes), countStyle: .file)
            throw HappierStore.RPCError(message: "\(draft.name) is larger than \(limit).", code: "attachment_too_large")
        }
        let initResponse = try await rpc("daemon.bulkTransfer.upload.init", [
            "t": "session_attachment_upload_v1",
            "messageLocalId": .string(localId),
            "fileName": .string(draft.name),
            "sizeBytes": .number(Double(draft.data.count)),
        ])
        guard let uploadId = initResponse["uploadId"]?.stringValue,
              let chunkSize = initResponse["chunkSizeBytes"]?.intValue, chunkSize > 0,
              let recipient = initResponse["recipientPublicKeyBase64"]?.stringValue
        else { throw HappierStore.RPCError(message: "The computer rejected the upload.", code: "upload_init_invalid") }
        do {
            var index = 0
            var offset = 0
            while offset < draft.data.count {
                try checkCancellation()
                let end = min(offset + chunkSize, draft.data.count)
                let chunk = try TransferChunk.encrypt(draft.data.subdata(in: offset..<end), uploadId: uploadId, index: index,
                                                      recipientPublicKeyBase64: recipient)
                _ = try await rpc("daemon.bulkTransfer.upload.chunk", [
                    "uploadId": .string(uploadId), "index": .number(Double(index)),
                    "payloadBase64": .string(chunk.payloadBase64),
                    "encryptedDataKeyEnvelopeBase64": .string(chunk.encryptedDataKeyEnvelopeBase64),
                ])
                progress(end - offset)
                index += 1
                offset = end
            }
            try checkCancellation()
            let finalized = try await rpc("daemon.bulkTransfer.upload.finalize", ["uploadId": .string(uploadId)])
            guard let path = finalized["path"]?.stringValue else {
                throw HappierStore.RPCError(message: "The computer didn't confirm the upload.", code: "upload_finalize_invalid")
            }
            return UploadedAttachment(name: draft.name, path: path, mimeType: draft.mimeType,
                                      sizeBytes: finalized["sizeBytes"]?.intValue ?? draft.data.count, sha256: finalized["sha256"]?.stringValue)
        } catch {
            do { _ = try await rpc("daemon.bulkTransfer.upload.abort", ["uploadId": .string(uploadId)]) } catch {
                log.notice("upload abort failed: \(String(describing: error), privacy: .public)")
            }
            throw error
        }
    }
}

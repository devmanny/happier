import Foundation
import Testing
@testable import HappierKit

@Suite @MainActor struct OutgoingSendTests {
    private func session(encrypted: Bool = false) throws -> Session {
        guard encrypted else { return try Session(row: ["id": "s", "encryptionMode": "plain"], keys: nil) }
        let keys = try AccountKeys(masterSecret: Data(repeating: 8, count: 32))
        let envelope = try HappierCrypto.sealDataKeyEnvelope(Data(repeating: 2, count: 32), recipientPublicKey: keys.content.publicKey)
        return try Session(row: ["id": "s", "encryptionMode": "e2ee", "dataEncryptionKey": .string(envelope.base64EncodedString())], keys: keys)
    }

    /// The real chunk cipher and message preparation run; only daemon/server network responses
    /// are controlled here. No existing attachment RPC fixture exists in the package.
    @MainActor private final class Network {
        let recipient = try! TransferRecipient(seed: Data(repeating: 7, count: 32))
        var names: [String] = []
        var bytes: [String: Data] = [:]
        var aborted: [String] = []
        var accepted: [(String, JSONValue, PendingAction)] = []
        var failPhoto: String?
        var loseEnqueueAck = false
        var onChunk: (() -> Void)?
        var onEnqueue: ((String, JSONValue) throws -> Void)?

        func rpc(_ method: String, _ params: JSONValue) async throws -> JSONValue {
            switch method {
            case "daemon.bulkTransfer.upload.init":
                let messageId = try #require(params["messageLocalId"]?.stringValue)
                #expect(!messageId.isEmpty)
                names.append(try #require(params["fileName"]?.stringValue))
                return ["uploadId": .string(String(names.count)), "chunkSizeBytes": 4,
                        "recipientPublicKeyBase64": .string(recipient.publicKeyBase64)]
            case "daemon.bulkTransfer.upload.chunk":
                let id = try #require(params["uploadId"]?.stringValue)
                let index = try #require(params["index"]?.intValue)
                if names[Int(id)! - 1] == failPhoto, index == 1 {
                    failPhoto = nil
                    throw URLError(.networkConnectionLost)
                }
                let chunk = try TransferChunk.decrypt(payloadBase64: #require(params["payloadBase64"]?.stringValue),
                    encryptedDataKeyEnvelopeBase64: #require(params["encryptedDataKeyEnvelopeBase64"]?.stringValue),
                    transferId: id, index: index, recipient: recipient)
                bytes[id, default: Data()].append(chunk)
                onChunk?()
                return ["success": true]
            case "daemon.bulkTransfer.upload.finalize":
                let id = try #require(params["uploadId"]?.stringValue)
                return ["path": .string("uploads/\(id)-\(names[Int(id)! - 1])"), "sizeBytes": .number(Double(bytes[id]?.count ?? 0))]
            case "daemon.bulkTransfer.upload.abort":
                aborted.append(try #require(params["uploadId"]?.stringValue))
                return ["success": true]
            default:
                Issue.record("Unexpected RPC: \(method)")
                throw URLError(.unsupportedURL)
            }
        }

        func enqueue(_ localId: String, _ content: JSONValue, _ action: PendingAction) async throws {
            accepted.append((localId, content, action))
            try onEnqueue?(localId, content)
            if loseEnqueueAck {
                loseEnqueueAck = false
                throw URLError(.networkConnectionLost)
            }
        }
    }

    @Test func sixPhotosKeepOriginalDataAndRetryOnlyTheUnfinishedFiles() async throws {
        let photos = (1...6).map { AttachmentDraft(name: "photo\($0).jpg", mimeType: "image/jpeg", data: Data(repeating: UInt8($0), count: 12)) }
        let send = OutgoingSend(sessionId: "s", text: "Revisa estas seis fotos", attachments: photos)
        let network = Network()
        network.failPhoto = "photo3.jpg"
        var progress = 0
        await #expect(throws: URLError.self) {
            try await send.deliver(context: { (try session(), [:]) }, rpc: network.rpc, enqueue: network.enqueue) { progress += $0 }
        }
        #expect(send.text == "Revisa estas seis fotos")
        #expect(send.attachments == photos)
        #expect(network.accepted.isEmpty)
        #expect(network.aborted == ["3"])
        progress = 0
        try await send.deliver(context: { (try session(), [:]) }, rpc: network.rpc, enqueue: network.enqueue) { progress += $0 }
        #expect(network.names == ["photo1.jpg", "photo2.jpg", "photo3.jpg", "photo3.jpg", "photo4.jpg", "photo5.jpg", "photo6.jpg"])
        #expect(progress == 72)
        let content = try #require(network.accepted.first?.1["v"])
        #expect(content["meta"]?["displayText"] == "Revisa estas seis fotos")
        #expect(content["meta"]?["happier"]?["payload"]?["attachments"]?.arrayValue?.count == 6)
        #expect(network.bytes["4"] == photos[2].data)
    }

    @Test func lostEnqueueAckRetriesTheExactEncryptedContentAndLocalId() async throws {
        let send = OutgoingSend(sessionId: "s", text: "mira", attachments: [AttachmentDraft(name: "a.jpg", mimeType: "image/jpeg", data: Data(repeating: 1, count: 4))])
        let network = Network()
        network.loseEnqueueAck = true
        let original = try session(encrypted: true)
        await #expect(throws: URLError.self) {
            try await send.deliver(context: { (original, ["source": "ui"]) }, rpc: network.rpc, enqueue: network.enqueue) { _ in }
        }
        var changedSession = original
        changedSession.active = true
        try await send.deliver(context: { (changedSession, ["source": "changed"]) }, rpc: network.rpc, enqueue: network.enqueue) { _ in }
        #expect(network.names == ["a.jpg"])
        #expect(network.accepted.count == 2)
        #expect(network.accepted[0].0 == network.accepted[1].0)
        #expect(network.accepted[0].1 == network.accepted[1].1)
        #expect(network.accepted[0].2 == network.accepted[1].2)
        var transcript = Transcript()
        transcript.addPending(localId: send.localId, text: send.text, attachments: send.attachments.map(\.name))
        let record = try #require(try original.decodeDocument(network.accepted[1].1))
        transcript.apply([TranscriptMessage(id: "remote", seq: 1, localId: send.localId, createdAt: .now, record: record)])
        #expect(transcript.items.count == 1)
    }

    @Test func transcriptConfirmationCompletesASendEvenWhenItsHttpAckIsLost() async throws {
        let send = OutgoingSend(sessionId: "s", text: "mira", attachments: [])
        let network = Network()
        network.loseEnqueueAck = true
        network.onEnqueue = { localId, content in
            let record = try #require(content["v"])
            let confirmation = TranscriptMessage(id: "remote", seq: 1, localId: localId, createdAt: .now, record: record)
            #expect(send.acknowledge(confirmation))
        }
        try await send.deliver(context: { (try session(), [:]) }, rpc: network.rpc, enqueue: network.enqueue) { _ in }
        #expect(network.accepted.count == 1)
    }

    @Test func anotherTranscriptMessageCannotHideAFailedSend() async throws {
        let send = OutgoingSend(sessionId: "s", text: "mira", attachments: [])
        let network = Network()
        network.loseEnqueueAck = true
        network.onEnqueue = { _, content in
            let record = try #require(content["v"])
            let unrelated = TranscriptMessage(id: "remote", seq: 1, localId: "another-message", createdAt: .now, record: record)
            #expect(!send.acknowledge(unrelated))
        }
        await #expect(throws: URLError.self) {
            try await send.deliver(context: { (try session(), [:]) }, rpc: network.rpc, enqueue: network.enqueue) { _ in }
        }
    }

    @Test(arguments: [false, true])
    func cancelledOwnerMakesNoFurtherRequests(includingPreparedSend: Bool) async throws {
        let send = OutgoingSend(sessionId: "s", text: "mira", attachments: [AttachmentDraft(name: "a.jpg", mimeType: "image/jpeg", data: Data(repeating: 1, count: 4))])
        let network = Network()
        if includingPreparedSend {
            network.loseEnqueueAck = true
            await #expect(throws: URLError.self) {
                try await send.deliver(context: { (try session(), [:]) }, rpc: network.rpc, enqueue: network.enqueue) { _ in }
            }
        }
        let requestCount = network.names.count
        let enqueueCount = network.accepted.count
        // Disconnecting the account cancels every retained owner, including one whose server
        // enqueue may already have succeeded. Neither its next upload nor prepared send may run.
        send.isCancelled = true
        await #expect(throws: CancellationError.self) {
            try await send.deliver(context: { (try session(), [:]) }, rpc: network.rpc, enqueue: network.enqueue) { _ in }
        }
        #expect(network.names.count == requestCount)
        #expect(network.accepted.count == enqueueCount)
    }

    @Test func cancellationDuringLastChunkNeverEnqueuesAndCanRetry() async throws {
        let send = OutgoingSend(sessionId: "s", text: "mira", attachments: [AttachmentDraft(name: "a.jpg", mimeType: "image/jpeg", data: Data(repeating: 1, count: 4))])
        let network = Network()
        network.onChunk = { send.isCancelled = true }
        await #expect(throws: CancellationError.self) {
            try await send.deliver(context: { (try session(), [:]) }, rpc: network.rpc, enqueue: network.enqueue) { _ in }
        }
        #expect(network.accepted.isEmpty)
        #expect(send.attachments.count == 1)
        #expect(network.aborted == ["1"])
        network.onChunk = nil
        send.isCancelled = false
        try await send.deliver(context: { (try session(), [:]) }, rpc: network.rpc, enqueue: network.enqueue) { _ in }
        #expect(network.accepted.count == 1)
    }
}

import CryptoKit
import Foundation
import os

/// Puts one file on the Mac mini.
public protocol OidoTransport: Sendable {
    /// Writes `data` at `path` on the target machine, replacing a file left by an earlier attempt.
    func put(_ data: Data, at path: String, sha256: String) async throws
}

/// The daemon's machine-scoped bulk-transfer upload (`registerBulkTransferUploadRpcHandlers.ts`,
/// `session_file_upload_v1`): end-to-end encrypted chunks through the relay, written by the daemon
/// at `path` (relative to its home folder, or absolute) after it checks size and sha256. No session
/// is needed, so it works from anywhere the app reaches the relay.
public struct OidoRelayTransport: OidoTransport {
    public typealias RPC = @Sendable (_ method: String, _ params: JSONValue) async throws -> JSONValue
    private let rpc: RPC

    public init(rpc: @escaping RPC) {
        self.rpc = rpc
    }

    public struct Rejected: LocalizedError {
        public let step: String
        public let message: String
        public var errorDescription: String? { "The computer refused the upload (\(step)): \(message)" }
    }

    public func put(_ data: Data, at path: String, sha256: String) async throws {
        let initResponse = try await rpc("daemon.bulkTransfer.upload.init", [
            "t": "session_file_upload_v1", "path": .string(path), "sizeBytes": .number(Double(data.count)),
            "overwrite": true, "sha256": .string(sha256),
        ])
        guard initResponse["success"]?.boolValue == true, let uploadId = initResponse["uploadId"]?.stringValue,
              let chunkSize = initResponse["chunkSizeBytes"]?.intValue, chunkSize > 0,
              let recipient = initResponse["recipientPublicKeyBase64"]?.stringValue, !recipient.isEmpty
        else { throw Rejected(step: "init", message: initResponse["error"]?.stringValue ?? "unexpected answer") }
        do {
            var index = 0
            var offset = 0
            while offset < data.count {
                try Task.checkCancellation()
                let end = min(offset + chunkSize, data.count)
                let chunk = try TransferChunk.encrypt(data.subdata(in: offset..<end), uploadId: uploadId, index: index,
                                                      recipientPublicKeyBase64: recipient)
                let answer = try await rpc("daemon.bulkTransfer.upload.chunk", [
                    "uploadId": .string(uploadId), "index": .number(Double(index)),
                    "payloadBase64": .string(chunk.payloadBase64),
                    "encryptedDataKeyEnvelopeBase64": .string(chunk.encryptedDataKeyEnvelopeBase64),
                ])
                guard answer["success"]?.boolValue != false else {
                    throw Rejected(step: "chunk \(index)", message: answer["error"]?.stringValue ?? "unexpected answer")
                }
                index += 1
                offset = end
            }
            let finalized = try await rpc("daemon.bulkTransfer.upload.finalize", ["uploadId": .string(uploadId)])
            guard finalized["success"]?.boolValue == true else {
                throw Rejected(step: "finalize", message: finalized["error"]?.stringValue ?? "unexpected answer")
            }
        } catch {
            _ = try? await rpc("daemon.bulkTransfer.upload.abort", ["uploadId": .string(uploadId)])
            throw error
        }
    }
}

/// Sends the spool to the Mac mini's inbox, oldest chunk first: the audio, then its manifest (the
/// inbox acts on a manifest only once its audio is whole), then drops it from the spool. Failures
/// wait 2 s, doubling up to a minute, like the Python client; the inbox ignores a chunk it already
/// has (`client_chunk_id`), so repeating an upload after a lost answer is harmless.
public actor OidoUploader {
    public struct Status: Sendable, Equatable {
        public var pending = 0
        public var isUploading = false
        public var lastUploadAt: Date?
        public var uploadedCount = 0
        public var lastError: String?
        public var retryAt: Date?
        public init() {}
    }

    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private let spool: OidoSpool
    private var transport: (any OidoTransport)?
    private var remoteDirectory: String
    private let sleep: Sleep
    private let now: @Sendable () -> Date
    private let onStatus: @Sendable (Status) -> Void
    private var status = Status()
    private var loop: Task<Void, Never>?
    private var wakeUp: CheckedContinuation<Void, Never>?
    private var woken = false
    private static let log = Logger(subsystem: "dev.happier.apple", category: "oido")

    public init(spool: OidoSpool, remoteDirectory: String, transport: (any OidoTransport)?,
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) }, now: @escaping @Sendable () -> Date = { Date() },
                onStatus: @escaping @Sendable (Status) -> Void = { _ in }) {
        self.spool = spool
        self.remoteDirectory = remoteDirectory
        self.transport = transport
        self.sleep = sleep
        self.now = now
        self.onStatus = onStatus
        status.pending = spool.count
    }

    /// Where on the target machine the chunk's files go: `<dir>/<device>/<file>`.
    public static func remotePath(directory: String, deviceId: String, file: String) -> String {
        var dir = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        while dir.count > 1, dir.hasSuffix("/") { dir.removeLast() }
        return (dir.isEmpty ? "" : dir + "/") + deviceId + "/" + file
    }

    public static func retryDelay(afterFailures failures: Int) -> Duration {
        .seconds(min(2 * pow(2, Double(max(failures - 1, 0))), 60))
    }

    public func configure(transport: (any OidoTransport)?, remoteDirectory: String) {
        self.transport = transport
        self.remoteDirectory = remoteDirectory
        wake()
    }

    /// Starts draining (what the last run left behind, then each new chunk).
    public func start() {
        guard loop == nil else { return }
        loop = Task { await run() }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        wake()
    }

    /// A chunk was queued, or the connection came back: try now.
    public func wake() {
        status.pending = spool.count
        publish()
        if let wakeUp {
            self.wakeUp = nil
            wakeUp.resume()
        } else {
            woken = true
        }
    }

    /// One pass over the spool; false at the first failure (that chunk stays).
    @discardableResult
    public func drainOnce() async -> Bool {
        for url in spool.pending() {
            if Task.isCancelled { return false }
            guard let transport else {
                fail("Choose the computer that receives the audio.")
                return false
            }
            status.isUploading = true
            publish()
            do {
                try await upload(url, via: transport)
                spool.remove(url)
                status.uploadedCount += 1
                status.lastUploadAt = now()
                status.lastError = nil
                status.retryAt = nil
                status.isUploading = false
                status.pending = spool.count
                publish()
            } catch {
                status.isUploading = false
                fail(UserFacingError.message(for: error))
                Self.log.error("oido upload failed: \(String(describing: error), privacy: .public)")
                return false
            }
        }
        status.pending = spool.count
        publish()
        return true
    }

    private func upload(_ url: URL, via transport: any OidoTransport) async throws {
        let manifest = try spool.manifest(at: url)
        let audio = try Data(contentsOf: spool.audioURL(for: manifest))
        let manifestData = try Data(contentsOf: url)
        try await transport.put(audio, at: Self.remotePath(directory: remoteDirectory, deviceId: manifest.deviceId, file: manifest.audioFile),
                                sha256: manifest.sha256)
        try await transport.put(manifestData, at: Self.remotePath(directory: remoteDirectory, deviceId: manifest.deviceId, file: url.lastPathComponent),
                                sha256: OidoHash.sha256(manifestData))
    }

    private func fail(_ message: String) {
        status.lastError = message
        status.pending = spool.count
        publish()
    }

    private func publish() {
        onStatus(status)
    }

    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            if await drainOnce() {
                failures = 0
                await waitForWake()
            } else {
                failures += 1
                let delay = Self.retryDelay(afterFailures: failures)
                status.retryAt = now().addingTimeInterval(Double(delay.components.seconds))
                publish()
                // A wake (new chunk, connection back) retries at once; otherwise after the delay.
                let sleeper = Task { [sleep] in
                    do {
                        try await sleep(delay)
                        self.wake()
                    } catch {}
                }
                await waitForWake()
                sleeper.cancel()
            }
        }
    }

    private func waitForWake() async {
        if woken {
            woken = false
            return
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { wakeUp = $0 }
        } onCancel: {
            Task { await self.wake() }
        }
        woken = false
    }
}

enum OidoHash {
    /// Lowercase hex, as the daemon and the inbox compare it.
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

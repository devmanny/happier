import AVFoundation
import Foundation
import Testing
@testable import HappierKit

/// Oído capture: the same speech gate and chunking as the Python client (`oido/vad.py`,
/// `oido/chunker.py`, vectors ported from `tests/test_core.py`), the spool the Mac mini's inbox
/// reads, and the upload over the daemon's bulk-transfer RPCs.
@Suite struct OidoTests {
    private static let sr = Oido.sampleRate

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "oido-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Speech gate (vad.py)

    private func regions(_ probs: [Float], _ params: OidoVADParameters) -> [Range<Int>] {
        var h = OidoHysteresis(params)
        var out: [Range<Int>] = []
        for (i, p) in probs.enumerated() { out += h.push(i, p) }
        return out + h.finish(probs.count)
    }

    @Test func hysteresisFindsTheSameRegionsAsThePythonClient() {
        // 1 s silence, 2 s speech, 1 s silence, 40 s speech, 1 s silence (test_hysteresis_regions_and_clips).
        let probs = [Float](repeating: 0, count: 31) + [Float](repeating: 0.9, count: 62) + [Float](repeating: 0, count: 31)
            + [Float](repeating: 0.9, count: 1250) + [Float](repeating: 0, count: 31)
        let found = regions(probs, OidoVADParameters(minSilenceSeconds: 0.5, padSeconds: 0.2, maxSpanSeconds: nil))
        // Padded by 6 frames (0.2 s) on both sides, ending after 16 frames (0.5 s) of quiet.
        #expect(found == [25..<99, 118..<1380])
    }

    @Test func longSpeechIsSplitIntoContiguousSpans() {
        let found = regions([Float](repeating: 0.9, count: 100), OidoVADParameters(padSeconds: 0, maxSpanSeconds: 1.0))
        #expect(found.first?.lowerBound == 0 && found.last?.upperBound == 100 && found.count > 1)
        for (a, b) in zip(found, found.dropFirst()) { #expect(a.upperBound == b.lowerBound) }
    }

    @Test func segmenterReturnsThePaddedSamplesOfEachSpan() {
        var segmenter = OidoSegmenter(OidoVADParameters(minSilenceSeconds: 0.5, padSeconds: 0.2))
        var spans: [OidoSpeechSpan] = []
        for i in 0..<200 {
            let speaking = (31..<93).contains(i)
            spans += segmenter.push([Float](repeating: Float(i), count: Oido.frameSamples), probability: speaking ? 0.9 : 0)
        }
        spans += segmenter.finish()
        #expect(spans.count == 1)
        #expect(spans[0].startFrame == 25)
        #expect(spans[0].samples.count == (99 - 25) * Oido.frameSamples)
        #expect(spans[0].samples.first == 25 && spans[0].samples.last == 98)
    }

    // MARK: Chunks (chunker.py)

    @Test func chunkBuilderJoinsSpansWithASpeechMap() {
        var b = OidoChunkBuilder(deviceId: "t", source: "file", targetSpeechSeconds: 3, maxSpanSeconds: 600, gapSeconds: 0.5,
                                 makeId: { "id" })
        let base = 1_000_000.0
        let second = [Float](repeating: 0.1, count: Self.sr)
        #expect(b.add(start: Date(timeIntervalSince1970: base + 10), samples: second).isEmpty)
        #expect(b.add(start: Date(timeIntervalSince1970: base + 11), samples: second).isEmpty) // contiguous: merged
        let out = b.add(start: Date(timeIntervalSince1970: base + 30), samples: second)        // 3 s of speech
        #expect(out.count == 1)
        #expect(out[0].startedAt.timeIntervalSince1970 == base + 10)
        #expect(out[0].speechMap == [[0, 0, 2], [2.5, 20, 1]])
        #expect(out[0].samples.count == Int(3.5 * Double(Self.sr)))
        #expect(b.isEmpty)
    }

    @Test func chunkBuilderFlushesOnSilenceAndOnMaxSpan() {
        var b = OidoChunkBuilder(deviceId: "t", source: "mic", targetSpeechSeconds: 100, maxSpanSeconds: 60, flushAfterSilenceSeconds: 5)
        let second = [Float](repeating: 0.1, count: Self.sr)
        _ = b.add(start: Date(timeIntervalSince1970: 0), samples: second)
        #expect(b.tick(now: Date(timeIntervalSince1970: 3)) == nil)
        #expect(b.tick(now: Date(timeIntervalSince1970: 6.5)) != nil)
        _ = b.add(start: Date(timeIntervalSince1970: 100), samples: second)
        let out = b.add(start: Date(timeIntervalSince1970: 170), samples: second) // would exceed the span
        #expect(out.count == 1 && out[0].startedAt.timeIntervalSince1970 == 100)
        #expect(b.flush()?.startedAt.timeIntervalSince1970 == 170)
    }

    // MARK: Late classifier windows

    @Test func framesWaitForTheClassifierWindowsThatCoverThem() {
        var scorer = OidoFrameScorer(silenceFloorDBFS: -60)
        let loud = [Float](repeating: 0.1, count: Oido.frameSamples)
        let quiet = [Float](repeating: 0.000_01, count: Oido.frameSamples)
        for i in 0..<4 { scorer.append(frame: i == 3 ? quiet : loud) }
        // Windows overlap by half (Apple's: 3 s, every 1.5 s). The first one alone settles nothing:
        // the next may still cover the same frames with more confidence (it lost a sentence's first word).
        #expect(scorer.add([OidoSpeechWindow(start: 0, end: 1536, confidence: 0.2)]).isEmpty)
        // Once a window starts after a frame, every window over that frame is known.
        let first = scorer.add([OidoSpeechWindow(start: 768, end: 2304, confidence: 0.9)])
        #expect(first.map(\.probability) == [0.2])
        // A frame takes its most confident window.
        let next = scorer.add([OidoSpeechWindow(start: 1536, end: 3072, confidence: 0.1)])
        #expect(next.map(\.probability) == [0.9, 0.9])
        // The end of the stream scores what's left; a quiet frame is never speech.
        #expect(scorer.flush().map(\.probability) == [0])
    }

    // MARK: Spool

    @Test func spoolWritesWhatTheInboxReads() throws {
        let dir = try tempDir()
        let spool = try OidoSpool(directory: dir)
        let chunk = OidoChunk(clientChunkId: "abc", deviceId: "abundia-pro", source: "happier-macos",
                              startedAt: Date(timeIntervalSince1970: 1_794_672_000.25), samples: [0, 0.5, -0.5],
                              speechMap: [[0, 0, 1.5]], final: true)
        let url = try spool.put(chunk) { samples, url in try Data(samples.map { UInt8(($0 + 1) * 100) }).write(to: url) }
        #expect(url.lastPathComponent == "1794672000250_abc.json")
        let json = try #require(try JSONValue.parse(Data(contentsOf: url)))
        #expect(json["client_chunk_id"]?.stringValue == "abc")
        #expect(json["device_id"]?.stringValue == "abundia-pro")
        #expect(json["audio_file"]?.stringValue == "1794672000250_abc.m4a")
        #expect(json["size_bytes"]?.intValue == 3)
        #expect(json["sha256"]?.stringValue == OidoHash.sha256(Data([100, 150, 50])))
        #expect(json["final"]?.boolValue == true)
        #expect(json["speech_map"] == [[0, 0, 1.5]])
        #expect(OidoManifest.timestamp(chunk.startedAt, timeZone: TimeZone(identifier: "America/Mexico_City")!)
            == "2026-11-14T10:00:00.250-06:00")
        #expect(spool.pending() == [url])
        spool.remove(url)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func spoolDropsAudioThatNeverGotItsManifest() throws {
        let dir = try tempDir()
        try Data([1]).write(to: dir.appending(path: "1_a.partial.m4a"))
        try Data([1]).write(to: dir.appending(path: "2_b.m4a"))
        try Data([1]).write(to: dir.appending(path: "3_c.m4a"))
        try Data("{}".utf8).write(to: dir.appending(path: "3_c.json"))
        let spool = try OidoSpool(directory: dir)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["3_c.json", "3_c.m4a"])
        #expect(spool.count == 1)
    }

    @Test func encoderWritesMonoAAC() throws {
        let url = try tempDir().appending(path: "tone.m4a")
        let samples = (0..<(20 * Self.sr)).map { Float(sin(2 * Double.pi * 220 * Double($0) / Double(Self.sr)) * 0.3) }
        try OidoAudioEncoder.writeM4A(samples, to: url)
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.channelCount == 1 && file.fileFormat.sampleRate == 16_000)
        #expect(abs(Double(file.length) / 16_000 - 20) < 0.2)
        // At most 32 kbit/s plus the container: a fraction of the 640 KB the same 20 s take as WAV.
        #expect(try Data(contentsOf: url).count < 20 * 32_000 / 8 + 30_000)
    }

    // MARK: Upload

    /// The daemon's bulk-transfer handlers, as far as the app sees them (their responses and the
    /// real chunk cipher); stands in for the relay.
    private actor Daemon {
        let recipient = try! TransferRecipient(seed: Data(repeating: 7, count: 32))
        var files: [String: Data] = [:]
        var inits: [JSONValue] = []
        var aborted = 0
        var failNextChunk = false
        private var uploads: [String: (path: String, data: Data)] = [:]

        func setFailNextChunk() { failNextChunk = true }

        func rpc(_ method: String, _ params: JSONValue) throws -> JSONValue {
            switch method {
            case "daemon.bulkTransfer.upload.init":
                inits.append(params)
                let id = "u\(inits.count)"
                uploads[id] = (params["path"]!.stringValue!, Data())
                return ["success": true, "uploadId": .string(id), "chunkSizeBytes": 1000,
                        "recipientPublicKeyBase64": .string(recipient.publicKeyBase64)]
            case "daemon.bulkTransfer.upload.chunk":
                if failNextChunk {
                    failNextChunk = false
                    throw URLError(.networkConnectionLost)
                }
                let id = params["uploadId"]!.stringValue!
                let bytes = try TransferChunk.decrypt(payloadBase64: params["payloadBase64"]!.stringValue!,
                                                      encryptedDataKeyEnvelopeBase64: params["encryptedDataKeyEnvelopeBase64"]!.stringValue!,
                                                      transferId: id, index: params["index"]!.intValue!, recipient: recipient)
                uploads[id]!.data.append(bytes)
                return ["success": true]
            case "daemon.bulkTransfer.upload.finalize":
                let upload = uploads[params["uploadId"]!.stringValue!]!
                files[upload.path] = upload.data
                return ["success": true, "path": .string(upload.path), "sizeBytes": .number(Double(upload.data.count))]
            case "daemon.bulkTransfer.upload.abort":
                aborted += 1
                return ["success": true]
            default:
                throw URLError(.unsupportedURL)
            }
        }
    }

    @Test func relayTransportWritesTheFileAtItsPathThroughEncryptedChunks() async throws {
        let daemon = Daemon()
        let transport = OidoRelayTransport { method, params in try await daemon.rpc(method, params) }
        let data = Data((0..<2500).map { UInt8($0 % 251) })
        try await transport.put(data, at: ".local/share/oido/inbox/mac/a.m4a", sha256: "abc")
        #expect(await daemon.files[".local/share/oido/inbox/mac/a.m4a"] == data)
        let request = try #require(await daemon.inits.first)
        #expect(request["t"]?.stringValue == "session_file_upload_v1")
        #expect(request["overwrite"]?.boolValue == true && request["sha256"]?.stringValue == "abc")
        #expect(request["sizeBytes"]?.intValue == 2500)

        await daemon.setFailNextChunk()
        await #expect(throws: URLError.self) { try await transport.put(data, at: "b", sha256: "x") }
        #expect(await daemon.aborted == 1)
        #expect(await daemon.files["b"] == nil)
    }

    @Test func relayTransportReportsTheDaemonsRefusal() async {
        let transport = OidoRelayTransport { _, _ in ["success": false, "error": "Access denied"] }
        await #expect(throws: OidoRelayTransport.Rejected.self) { try await transport.put(Data([1]), at: "/x", sha256: "s") }
    }

    @Test func uploaderSendsAudioThenManifestOldestFirstAndKeepsWhatFailed() async throws {
        let dir = try tempDir()
        let spool = try OidoSpool(directory: dir)
        let encode: ([Float], URL) throws -> Void = { samples, url in try Data(repeating: 9, count: samples.count).write(to: url) }
        for (i, id) in ["b", "a"].enumerated() {
            try spool.put(OidoChunk(clientChunkId: id, deviceId: "mac", source: "s", startedAt: Date(timeIntervalSince1970: Double(10 + i)),
                                    samples: [0, 0], speechMap: [[0, 0, 0.1]], final: false), encode: encode)
        }
        let daemon = Daemon()
        let statuses = Statuses()
        let uploader = OidoUploader(spool: spool, remoteDirectory: "inbox/", transport: nil, onStatus: { statuses.add($0) })
        #expect(await uploader.drainOnce() == false)
        #expect(statuses.last?.lastError != nil && spool.count == 2)

        await daemon.setFailNextChunk()
        await uploader.configure(transport: OidoRelayTransport { try await daemon.rpc($0, $1) }, remoteDirectory: "inbox/")
        #expect(await uploader.drainOnce() == false)
        #expect(spool.count == 2 && statuses.last?.lastError != nil)

        #expect(await uploader.drainOnce() == true)
        #expect(spool.count == 0)
        let paths = await daemon.inits.compactMap { $0["path"]?.stringValue }
        #expect(Array(paths.suffix(4)) == ["inbox/mac/10000_b.m4a", "inbox/mac/10000_b.json", "inbox/mac/11000_a.m4a", "inbox/mac/11000_a.json"])
        let manifest = try #require(await daemon.files["inbox/mac/10000_b.json"])
        #expect(try JSONDecoder().decode(OidoManifest.self, from: manifest).sha256 == OidoHash.sha256(Data(repeating: 9, count: 2)))
        let last = try #require(statuses.last)
        #expect(last.lastError == nil && last.uploadedCount == 2 && last.pending == 0 && last.lastUploadAt != nil)
    }

    @Test func retriesBackOffUpToAMinute() {
        #expect((1...7).map { OidoUploader.retryDelay(afterFailures: $0) } == [2, 4, 8, 16, 32, 60, 60].map { Duration.seconds($0) })
        #expect(OidoUploader.remotePath(directory: "/srv/inbox//", deviceId: "d", file: "f") == "/srv/inbox/d/f")
    }

    @Test func uploaderRetriesOnItsOwnAfterAFailure() async throws {
        let dir = try tempDir()
        let spool = try OidoSpool(directory: dir)
        try spool.put(OidoChunk(clientChunkId: "a", deviceId: "mac", source: "s", startedAt: Date(), samples: [0],
                                speechMap: [[0, 0, 0.1]], final: false)) { _, url in try Data([1]).write(to: url) }
        let daemon = Daemon()
        await daemon.setFailNextChunk()
        let uploader = OidoUploader(spool: spool, remoteDirectory: "i", transport: OidoRelayTransport { try await daemon.rpc($0, $1) },
                                    sleep: { _ in try await Task.sleep(for: .milliseconds(10)) })
        await uploader.start()
        for _ in 0..<200 where spool.count > 0 { try await Task.sleep(for: .milliseconds(10)) }
        await uploader.stop()
        #expect(spool.count == 0)
        #expect(await daemon.aborted == 1)
    }

    @Test func deviceIdsAreWhatTheServerAccepts() {
        #expect(Oido.deviceId(from: "Abundia-Pro") == "abundia-pro")
        #expect(Oido.deviceId(from: "iPad de Manny") == "ipad-de-manny")
        #expect(Oido.deviceId(from: "…") == nil)
        #expect(Oido.deviceId(from: String(repeating: "a", count: 80))?.count == 64)
    }

    // MARK: Pipeline

    @Test func pipelineChunksSpeechByTheStreamClock() throws {
        let dir = try tempDir()
        let spool = try OidoSpool(directory: dir)
        var settings = OidoPipeline.Settings(deviceId: "mac", source: "test")
        settings.flushAfterSilenceSeconds = 5
        let pipeline = OidoPipeline(settings: settings, spool: spool, makeClassifier: { OidoLoudnessClassifier() },
                                    encode: { samples, url in try Data(count: samples.count * 2).write(to: url) })
        let start = Date(timeIntervalSince1970: 1_794_672_000)
        pipeline.begin(at: start)
        var noise = SystemRandomNumberGenerator()
        func room(_ seconds: Double) -> [Float] { (0..<Int(seconds * Double(Self.sr))).map { _ in Float.random(in: -0.001...0.001, using: &noise) } }
        func voice(_ seconds: Double) -> [Float] {
            (0..<Int(seconds * Double(Self.sr))).map { Float(sin(2 * Double.pi * 180 * Double($0) / Double(Self.sr)) * 0.3) }
        }
        var queued: [URL] = []
        for piece in [room(3), voice(2), room(1), voice(1), room(8), voice(1.5), room(1)] {
            // Odd slice sizes, like a microphone tap.
            var rest = piece[...]
            while !rest.isEmpty {
                queued += try pipeline.append(Array(rest.prefix(4_410)))
                rest = rest.dropFirst(4_410)
            }
        }
        #expect(queued.count == 1) // the long silence closed the first chunk
        queued += try pipeline.end(final: true)
        #expect(queued.count == 2)
        let first = try spool.manifest(at: queued[0])
        let second = try spool.manifest(at: queued[1])
        #expect(first.speechMap.count == 2 && !first.final && second.final)
        let firstStart = try #require(ISO8601DateFormatter.withFractions.date(from: first.startedAt))
        // Speech began 3 s in; the gate keeps ≤ 0.3 s of padding before it.
        #expect(abs(firstStart.timeIntervalSince(start) - 3) < 0.35)
        #expect(abs(first.speechMap[1][1] - (6 - firstStart.timeIntervalSince(start))) < 0.35)
        let secondStart = try #require(ISO8601DateFormatter.withFractions.date(from: second.startedAt))
        #expect(abs(secondStart.timeIntervalSince(start) - 15) < 0.35)
    }
}

private final class Statuses: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [OidoUploader.Status] = []
    func add(_ s: OidoUploader.Status) { lock.withLock { all.append(s) } }
    var last: OidoUploader.Status? { lock.withLock { all.last } }
}

private extension ISO8601DateFormatter {
    static var withFractions: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
}

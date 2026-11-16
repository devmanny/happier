import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// What travels with a chunk's audio: the fields of the Python client's spool (`oido/spool.py`)
/// plus the audio's size and hash, so the Mac mini's inbox (`oido/inbox.py`) only takes it once
/// the audio arrived whole. Keys are the inbox's (snake case).
public struct OidoManifest: Codable, Sendable, Equatable {
    public var v = 1
    public var clientChunkId: String
    public var deviceId: String
    public var source: String
    /// ISO 8601 with the local offset and milliseconds, e.g. `2026-11-14T10:00:00.000-06:00`.
    public var startedAt: String
    public var durationS: Double
    public var speechMap: [[Double]]
    public var final: Bool
    public var audioFile: String
    public var sizeBytes: Int
    public var sha256: String
    public var contentType: String

    enum CodingKeys: String, CodingKey {
        case v, source, final, sha256
        case clientChunkId = "client_chunk_id", deviceId = "device_id", startedAt = "started_at", durationS = "duration_s"
        case speechMap = "speech_map", audioFile = "audio_file", sizeBytes = "size_bytes", contentType = "content_type"
    }

    public static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}

/// Chunks waiting to reach the Mac mini, on disk: `<startMs>_<id>.m4a` written first, then its
/// `<startMs>_<id>.json` manifest. A chunk is pending once its manifest exists and leaves only
/// when the upload is confirmed, so a crash, a reboot or days offline lose nothing.
public struct OidoSpool: Sendable {
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Audio without a manifest was being written when the app stopped: incomplete, never queued.
        let names = Set(Self.names(in: directory))
        for name in names where !name.hasSuffix(".json") {
            let base = name.components(separatedBy: ".").first ?? name
            if !names.contains(base + ".json") { try? FileManager.default.removeItem(at: directory.appending(path: name)) }
        }
    }

    private static func names(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    /// Encodes the chunk and queues it; returns its manifest's file.
    @discardableResult
    public func put(_ chunk: OidoChunk, encode: (_ samples: [Float], _ url: URL) throws -> Void = OidoAudioEncoder.writeM4A) throws -> URL {
        let base = "\(Int64((chunk.startedAt.timeIntervalSince1970 * 1000).rounded()))_\(chunk.clientChunkId)"
        let audio = directory.appending(path: base + ".m4a")
        let partial = directory.appending(path: base + ".partial.m4a")
        try? FileManager.default.removeItem(at: partial)
        try encode(chunk.samples, partial)
        try? FileManager.default.removeItem(at: audio)
        try FileManager.default.moveItem(at: partial, to: audio)
        let data = try Data(contentsOf: audio)
        let manifest = OidoManifest(
            clientChunkId: chunk.clientChunkId, deviceId: chunk.deviceId, source: chunk.source,
            startedAt: OidoManifest.timestamp(chunk.startedAt), durationS: (chunk.durationSeconds * 1000).rounded() / 1000,
            speechMap: chunk.speechMap, final: chunk.final, audioFile: audio.lastPathComponent, sizeBytes: data.count,
            sha256: OidoHash.sha256(data), contentType: "audio/mp4")
        let url = directory.appending(path: base + ".json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: url, options: .atomic)
        return url
    }

    /// Queued manifests, oldest chunk first.
    public func pending() -> [URL] {
        Self.names(in: directory).filter { $0.hasSuffix(".json") }.sorted().map { directory.appending(path: $0) }
    }

    public var count: Int { pending().count }

    public func manifest(at url: URL) throws -> OidoManifest {
        try JSONDecoder().decode(OidoManifest.self, from: Data(contentsOf: url))
    }

    public func audioURL(for manifest: OidoManifest) -> URL {
        directory.appending(path: manifest.audioFile)
    }

    /// Delivered: the manifest goes first, so a crash in between leaves only orphan audio (removed on open).
    public func remove(_ url: URL) {
        let audio = (try? manifest(at: url)).map(audioURL(for:))
        try? FileManager.default.removeItem(at: url)
        if let audio { try? FileManager.default.removeItem(at: audio) }
    }
}

#if canImport(AVFoundation)
public enum OidoAudioEncoder {
    /// AAC in an `.m4a`, mono 16 kHz at 32 kbit/s: about 14 MB per hour of speech.
    public static func writeM4A(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Double(Oido.sampleRate),
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let piece = 16_384
        var offset = 0
        while offset < samples.count {
            let count = min(piece, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)) else {
                throw CocoaError(.fileWriteUnknown)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress! + offset, count: count) }
            try file.write(from: buffer)
            offset += count
        }
        file.close()
    }
}
#endif

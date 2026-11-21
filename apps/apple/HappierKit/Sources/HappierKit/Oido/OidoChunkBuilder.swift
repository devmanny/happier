import Foundation

/// One upload: speech spans joined with short silent gaps, and the map back to wall-clock time
/// (`oido/chunker.py` `Chunk`). `speechMap` entries are `[chunkOffset, wallOffset, length]` in
/// seconds, `wallOffset` relative to `startedAt`, so the Mac mini dates every transcribed word.
public struct OidoChunk: Sendable, Equatable {
    public let clientChunkId: String
    public let deviceId: String
    public let source: String
    public let startedAt: Date
    public let samples: [Float]
    public let speechMap: [[Double]]
    public var final: Bool

    public var durationSeconds: Double { Double(samples.count) / Double(Oido.sampleRate) }
    public var speechSeconds: Double { speechMap.reduce(0) { $0 + $1[2] } }
}

/// Builds chunks out of speech spans like the Python capture client (`ChunkBuilder`): a chunk
/// closes at `targetSpeechSeconds` of speech, after `flushAfterSilenceSeconds` without speech,
/// or once it spans `maxSpanSeconds` of wall time.
public struct OidoChunkBuilder: Sendable {
    public let deviceId: String
    public let source: String
    public var targetSpeechSeconds: Double
    public var maxSpanSeconds: Double
    public var flushAfterSilenceSeconds: Double
    public var gapSeconds: Double
    private let makeId: @Sendable () -> String

    private var parts: [Float] = []
    private var map: [[Double]] = []
    private var startedAt: Double?
    private var speechSamples = 0
    private var lastEnd: Double?

    public init(deviceId: String, source: String, targetSpeechSeconds: Double = 180, maxSpanSeconds: Double = 600,
                flushAfterSilenceSeconds: Double = 45, gapSeconds: Double = 0.4,
                makeId: @escaping @Sendable () -> String = { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }) {
        self.deviceId = deviceId
        self.source = source
        self.targetSpeechSeconds = targetSpeechSeconds
        self.maxSpanSeconds = maxSpanSeconds
        self.flushAfterSilenceSeconds = flushAfterSilenceSeconds
        self.gapSeconds = gapSeconds
        self.makeId = makeId
    }

    public var isEmpty: Bool { startedAt == nil }

    /// `start`: wall-clock time of the span's first sample.
    public mutating func add(start: Date, samples: [Float]) -> [OidoChunk] {
        var out: [OidoChunk] = []
        guard !samples.isEmpty else { return out }
        let startTs = start.timeIntervalSince1970
        let length = Double(samples.count) / Double(Oido.sampleRate)
        if let startedAt, startTs + length - startedAt > maxSpanSeconds { out.append(emit()) }
        if startedAt == nil { startedAt = startTs }
        let wallOffset = startTs - startedAt!
        if let lastEnd, abs(startTs - lastEnd) < 1e-3, !map.isEmpty {
            map[map.count - 1][2] += length
        } else {
            if lastEnd != nil { parts += [Float](repeating: 0, count: Int(gapSeconds * Double(Oido.sampleRate))) }
            map.append([Double(parts.count) / Double(Oido.sampleRate), wallOffset, length])
        }
        parts += samples
        speechSamples += samples.count
        lastEnd = startTs + length
        if Double(speechSamples) / Double(Oido.sampleRate) >= targetSpeechSeconds { out.append(emit()) }
        return out
    }

    /// Flushes after a long silence or once the chunk spans too much wall time.
    public mutating func tick(now: Date) -> OidoChunk? {
        guard let startedAt, let lastEnd else { return nil }
        let t = now.timeIntervalSince1970
        guard t - lastEnd >= flushAfterSilenceSeconds || t - startedAt >= maxSpanSeconds else { return nil }
        return emit()
    }

    public mutating func flush() -> OidoChunk? {
        startedAt == nil ? nil : emit()
    }

    private mutating func emit() -> OidoChunk {
        let round4 = { (v: Double) in (v * 10_000).rounded() / 10_000 }
        let chunk = OidoChunk(clientChunkId: makeId(), deviceId: deviceId, source: source,
                              startedAt: Date(timeIntervalSince1970: startedAt!), samples: parts,
                              speechMap: map.map { $0.map(round4) }, final: false)
        parts = []
        map = []
        startedAt = nil
        speechSamples = 0
        lastEnd = nil
        return chunk
    }
}

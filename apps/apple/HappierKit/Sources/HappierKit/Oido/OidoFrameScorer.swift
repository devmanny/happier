import Foundation

/// A classifier's verdict on a stretch of the stream: samples `[start, end)` (16 kHz, from the
/// stream's start) and how sure it is that someone is speaking.
public struct OidoSpeechWindow: Sendable, Equatable {
    public let start: Int
    public let end: Int
    public let confidence: Float

    public init(start: Int, end: Int, confidence: Float) {
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

/// Says where the speech is. Gets the stream in order; may answer later than the audio it covers.
public protocol OidoSpeechClassifier: AnyObject {
    func analyze(_ samples: [Float], at position: Int) -> [OidoSpeechWindow]
    /// Whatever is still pending at the end of a stream.
    func finish() -> [OidoSpeechWindow]
}

/// Gives each 32 ms frame a speech probability once every classifier window over it is known:
/// Apple's sound classifier answers per 3 s window, every 1.5 s, after the fact. Windows come in
/// order, so a frame is settled once a window starts at or after its end. A frame takes the most
/// confident window that overlaps it (keeping speech beats trimming it: the Mac mini re-runs
/// Silero), and a frame quieter than `silenceFloorDBFS` never counts as speech.
public struct OidoFrameScorer: Sendable {
    public struct Scored: Sendable, Equatable {
        public let samples: [Float]
        public let probability: Float
    }

    public var silenceFloorDBFS: Float
    private var queue: [(index: Int, samples: [Float], loud: Bool)] = []
    private var windows: [OidoSpeechWindow] = []
    private var nextIndex = 0
    /// Frames ending here or earlier have all their windows.
    private var settled = 0

    public init(silenceFloorDBFS: Float = -60) {
        self.silenceFloorDBFS = silenceFloorDBFS
    }

    public mutating func append(frame: [Float]) {
        queue.append((nextIndex, frame, OidoLevel.dbfs(frame) >= silenceFloorDBFS))
        nextIndex += 1
    }

    /// Frames whose windows are now all known, in order.
    public mutating func add(_ newWindows: [OidoSpeechWindow]) -> [Scored] {
        for window in newWindows where window.end > window.start {
            windows.append(window)
            settled = max(settled, window.start)
        }
        var out: [Scored] = []
        while let first = queue.first, (first.index + 1) * Oido.frameSamples <= settled {
            out.append(score(queue.removeFirst()))
        }
        let nextStart = (queue.first?.index ?? nextIndex) * Oido.frameSamples
        windows.removeAll { $0.end <= nextStart }
        return out
    }

    /// Every queued frame, scored with what is known (end of a stream).
    public mutating func flush() -> [Scored] {
        let out = queue.map(score)
        queue.removeAll()
        windows.removeAll()
        return out
    }

    private func score(_ frame: (index: Int, samples: [Float], loud: Bool)) -> Scored {
        guard frame.loud else { return Scored(samples: frame.samples, probability: 0) }
        let start = frame.index * Oido.frameSamples, end = start + Oido.frameSamples
        let best = windows.lazy.filter { $0.start < end && $0.end > start }.map(\.confidence).max() ?? 0
        return Scored(samples: frame.samples, probability: best)
    }
}

public enum OidoLevel {
    /// RMS level in dBFS (−120 for digital silence).
    public static func dbfs(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -120 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(samples.count)).squareRoot()
        return rms > 0 ? max(20 * log10(rms), -120) : -120
    }
}

/// Speech by loudness alone: a frame well above the room's noise floor (tracked down fast, up
/// slowly) counts as speech. The fallback when Apple's classifier can't run, and a deterministic
/// classifier for tests.
public final class OidoLoudnessClassifier: OidoSpeechClassifier {
    private var floor: Float?
    /// How far above the noise floor speech starts, and the dB range over which it becomes certain.
    private let margin: Float
    private let ramp: Float
    /// dB per frame the floor may rise (≈ 3 dB every 10 s).
    private let rise: Float = 0.01
    private var pending: [Float] = []
    private var position = 0

    public init(margin: Float = 9, ramp: Float = 9) {
        self.margin = margin
        self.ramp = ramp
    }

    public func analyze(_ samples: [Float], at position: Int) -> [OidoSpeechWindow] {
        if pending.isEmpty { self.position = position }
        pending += samples
        var out: [OidoSpeechWindow] = []
        while pending.count >= Oido.frameSamples {
            let frame = Array(pending.prefix(Oido.frameSamples))
            pending.removeFirst(Oido.frameSamples)
            let db = OidoLevel.dbfs(frame)
            let current = floor.map { min(db, $0 + rise) } ?? db
            floor = current
            let confidence = min(max((db - current - margin) / ramp + 0.5, 0), 1)
            out.append(OidoSpeechWindow(start: self.position, end: self.position + Oido.frameSamples, confidence: confidence))
            self.position += Oido.frameSamples
        }
        return out
    }

    public func finish() -> [OidoSpeechWindow] {
        defer { pending.removeAll() }
        guard !pending.isEmpty else { return [] }
        return [OidoSpeechWindow(start: position, end: position + pending.count, confidence: 0)]
    }
}

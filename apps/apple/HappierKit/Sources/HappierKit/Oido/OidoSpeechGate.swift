import Foundation

/// Oído's on-device speech gate, a port of `oido/vad.py` (`Hysteresis`, `StreamingSegmenter`):
/// 512-sample frames at 16 kHz with a speech probability each in, finished speech spans out.
/// The probability comes from `OidoFrameScorer` (Apple's sound classifier and/or loudness);
/// the Mac mini runs Silero on every chunk again, so the gate only has to keep the speech.
public enum Oido {
    public static let sampleRate = 16_000
    public static let frameSamples = 512
    public static let frameSeconds = Double(frameSamples) / Double(sampleRate)

    static func frames(for seconds: Double) -> Int { max(1, Int((seconds / frameSeconds).rounded())) }

    /// A `device_id` the server accepts (letters, digits, `.`, `_`, `-`; up to 64; starting with a
    /// letter or digit), from a host or device name; nil when nothing usable is left.
    public static func deviceId(from name: String) -> String? {
        let mapped = name.lowercased().map { c -> Character in
            c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "_" || c == "-") ? c : "-"
        }
        let trimmed = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        return trimmed.isEmpty ? nil : String(trimmed.prefix(64))
    }
}

public struct OidoVADParameters: Sendable, Equatable {
    public var threshold: Float
    /// Default `threshold - 0.15` (never below 0.05).
    public var negativeThreshold: Float?
    public var minSpeechSeconds: Double
    public var minSilenceSeconds: Double
    public var padSeconds: Double
    /// Very long speech is split into spans of at most this much (the Python client uses 60 s).
    public var maxSpanSeconds: Double?

    public init(threshold: Float = 0.5, negativeThreshold: Float? = nil, minSpeechSeconds: Double = 0.25,
                minSilenceSeconds: Double = 0.6, padSeconds: Double = 0.3, maxSpanSeconds: Double? = 60) {
        self.threshold = threshold
        self.negativeThreshold = negativeThreshold
        self.minSpeechSeconds = minSpeechSeconds
        self.minSilenceSeconds = minSilenceSeconds
        self.padSeconds = padSeconds
        self.maxSpanSeconds = maxSpanSeconds
    }
}

/// Per-frame probabilities to speech regions `[start, end)` in frames, padded on both sides,
/// never overlapping what was already emitted (`vad.py` `Hysteresis`).
struct OidoHysteresis {
    let threshold: Float
    let negative: Float
    let minSpeech: Int
    let minSilence: Int
    let pad: Int
    let maxSpan: Int?
    private(set) var inSpeech = false
    private var continued = false
    private var start = 0
    private var lastVoiced = -1
    private var emittedUntil = 0

    init(_ p: OidoVADParameters) {
        threshold = p.threshold
        negative = p.negativeThreshold ?? max(0.05, p.threshold - 0.15)
        minSpeech = Oido.frames(for: p.minSpeechSeconds)
        minSilence = Oido.frames(for: p.minSilenceSeconds)
        pad = p.padSeconds > 0 ? min(Oido.frames(for: p.padSeconds), minSilence - 1) : 0
        maxSpan = p.maxSpanSeconds.map(Oido.frames(for:))
    }

    private var lowerBound: Int { max(start - pad, emittedUntil, 0) }

    private mutating func emit(_ end: Int) -> Range<Int> {
        let s = lowerBound
        emittedUntil = end
        return s..<end
    }

    private mutating func close(_ end: Int) -> [Range<Int>] {
        inSpeech = false
        if end - start >= minSpeech || continued, end > lowerBound { return [emit(end)] }
        return []
    }

    mutating func push(_ i: Int, _ prob: Float) -> [Range<Int>] {
        if !inSpeech {
            if prob >= threshold {
                inSpeech = true
                continued = false
                start = i
                lastVoiced = i
            }
            return []
        }
        if prob >= negative {
            lastVoiced = i
        } else if i - lastVoiced >= minSilence {
            return close(min(lastVoiced + 1 + pad, i + 1))
        }
        if let maxSpan, i + 1 - lowerBound >= maxSpan {
            let region = emit(i + 1)
            start = i + 1
            continued = true
            return [region]
        }
        return []
    }

    mutating func finish(_ frameCount: Int) -> [Range<Int>] {
        guard inSpeech else { return [] }
        return close(min(frameCount, lastVoiced + 1 + pad))
    }
}

/// A finished stretch of speech: its first frame (counted from the stream's start) and samples.
public struct OidoSpeechSpan: Sendable, Equatable {
    public let startFrame: Int
    public let samples: [Float]
}

/// Feed frames with their probability; get back finished speech spans (`StreamingSegmenter`).
/// Keeps only the frames a span may still need (the padding before speech, or the open span).
public struct OidoSegmenter: Sendable {
    private var hysteresis: OidoHysteresis
    private var frames: [(index: Int, samples: [Float])] = []
    public private(set) var frameCount = 0

    public init(_ parameters: OidoVADParameters = .init()) {
        hysteresis = OidoHysteresis(parameters)
    }

    public var inSpeech: Bool { hysteresis.inSpeech }

    public mutating func push(_ frame: [Float], probability: Float) -> [OidoSpeechSpan] {
        let i = frameCount
        frameCount += 1
        frames.append((i, frame))
        let spans = hysteresis.push(i, probability).map { cut($0) }
        if !hysteresis.inSpeech, frames.count > hysteresis.pad + 1 {
            frames.removeFirst(frames.count - (hysteresis.pad + 1))
        }
        return spans
    }

    public mutating func finish() -> [OidoSpeechSpan] {
        hysteresis.finish(frameCount).map { cut($0) }
    }

    private mutating func cut(_ range: Range<Int>) -> OidoSpeechSpan {
        var samples: [Float] = []
        for frame in frames where range.contains(frame.index) { samples += frame.samples }
        frames.removeAll { $0.index < range.upperBound }
        return OidoSpeechSpan(startFrame: range.lowerBound, samples: samples)
    }
}

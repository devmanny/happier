import Foundation

/// Where a take's speech ends. Whisper writes words for silence ("Gracias.", "[MÚSICA]"): the
/// quiet after the last words, or a take with no speech at all, is not given to it.
public enum DictationSpeech {
    /// One loudness frame, in seconds.
    public static let frameSeconds = 0.1
    /// Kept after the last loud frame so the end of the last word isn't cut.
    private static let marginFrames = 4

    /// How many of the take's frames (loudness in dBFS, `frameSeconds` each) to transcribe, or nil
    /// when nothing in it is speech. Speech is 12 dB above the take's own background (its quietest
    /// tenth), so a soft voice in a quiet room counts and steady room noise does not.
    public static func speechEnd(frameLevels levels: [Float]) -> Int? {
        guard !levels.isEmpty else { return nil }
        let background = levels.sorted()[levels.count / 10]
        let threshold = max(background + 12, -55)
        guard let last = levels.lastIndex(where: { $0 > threshold }) else { return nil }
        return min(levels.count, last + 1 + marginFrames)
    }

    /// A frame's loudness in dBFS.
    public static func level(of samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return -120 }
        let power = samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)
        return 10 * log10(max(power, 1e-12))
    }
}

/// The text of one live Whisper dictation. Each pass transcribes the audio after the last
/// confirmed segment; a segment is confirmed once two more follow it (Whisper revises the last
/// ones as audio arrives), and the final pass confirms everything.
public struct WhisperStreamTranscript: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        public let text: String
        public let start: Float
        public let end: Float

        public init(text: String, start: Float, end: Float) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    /// Unconfirmed segments kept open for revision.
    private static let openSegments = 2

    /// Where the next pass starts, in seconds of the take.
    public private(set) var confirmedEnd: Float = 0
    private var confirmed: [String] = []
    private var pending: [String] = []

    public init() {}

    public var text: String {
        (confirmed + pending)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The segments of a pass that started at `confirmedEnd`.
    public mutating func update(_ segments: [Segment], final: Bool) {
        let settled = final ? segments.count : max(0, segments.count - Self.openSegments)
        let done = segments.prefix(settled)
        if let last = done.last, final || last.end > confirmedEnd {
            confirmed += done.map(\.text)
            confirmedEnd = max(confirmedEnd, last.end)
        }
        pending = segments.dropFirst(settled).map(\.text)
    }
}

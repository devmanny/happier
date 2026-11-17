import Foundation

/// Where a take's speech ends. Whisper writes words for silence and for any noise in it
/// ("Gracias.", "Gracias por ver el video.", "[MÚSICA]"), confidently: the quiet after the last
/// words, a take with no speech, and short noises (a tap, a rustle) are not given to it.
public enum DictationSpeech {
    /// One loudness frame, in seconds.
    public static let frameSeconds = 0.1
    /// Kept after the last loud frame so the end of the last word isn't cut.
    private static let marginFrames = 4
    /// Speech is sustained: even "sí" or "no" said softly is 0.3 s loud; a tap or a rustle on the
    /// phone is 0.2 s at most (measured on synthetic voices and noise bursts over room noise).
    private static let minimumSpeechFrames = 3

    /// How many of the take's frames (loudness in dBFS, `frameSeconds` each) to transcribe, or nil
    /// when nothing in it is speech. Speech is 12 dB above the take's own background (its quietest
    /// tenth), so a soft voice in a quiet room counts and steady room noise does not, and lasts
    /// `minimumSpeechFrames`, so a short noise doesn't.
    public static func speechEnd(frameLevels levels: [Float]) -> Int? {
        guard let last = speechFrames(frameLevels: levels).last else { return nil }
        return min(levels.count, last + 1 + marginFrames)
    }

    /// Seconds of speech in the take from frame `from` on.
    public static func speechSeconds(frameLevels levels: [Float], from: Int) -> Float {
        Float(speechFrames(frameLevels: levels).count { $0 >= from }) / Float(1 / frameSeconds)
    }

    /// The frames that are speech: loud, in runs of at least `minimumSpeechFrames`.
    private static func speechFrames(frameLevels levels: [Float]) -> [Int] {
        guard let background = background(frameLevels: levels) else { return [] }
        let threshold = max(background + 12, -55)
        var frames: [Int] = []
        var run: [Int] = []
        for (index, level) in levels.enumerated() {
            if level > threshold {
                run.append(index)
                continue
            }
            if run.count >= minimumSpeechFrames { frames += run }
            run.removeAll()
        }
        if run.count >= minimumSpeechFrames { frames += run }
        return frames
    }

    /// The take's background loudness: its quietest tenth.
    public static func background(frameLevels levels: [Float]) -> Float? {
        levels.isEmpty ? nil : levels.sorted()[levels.count / 10]
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
/// ones as audio arrives), and the final pass confirms everything. A pass never takes words off the
/// screen: one that decodes nothing leaves what was shown, so the composer doesn't blink.
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

    /// The take's audio a pass reads, in seconds. Past the take's speech it is silence.
    public struct Pass: Equatable, Sendable {
        public let start: Float
        public let end: Float

        public init(start: Float, end: Float) {
            self.start = start
            self.end = end
        }
    }

    /// Unconfirmed segments kept open for revision.
    private static let openSegments = 2

    /// Where the next pass starts, in seconds of the take.
    public private(set) var confirmedEnd: Float = 0
    private var confirmed: [Segment] = []
    /// The text after `confirmedEnd`, as last decoded.
    private var pending: [String] = []
    /// The take's language ("es"), when known.
    private let language: String?
    /// Words Whisper wrote in lowercase in this take: the same word capitalized at the start of a
    /// pass, mid-sentence, is a pass decoded out of context, not a name.
    private var lowercaseWords: Set<String> = []

    public init(language: String? = nil) {
        self.language = language
    }

    public var text: String {
        let text = (confirmed.map(\.text) + pending)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return language?.hasPrefix("es") == true ? Self.yesNotC(text) : text
    }

    /// Whisper hears a lone Spanish "sí" as the letter "C." (3 of 4 voices tried); a take that is
    /// only that letter is "Sí".
    static func yesNotC(_ text: String) -> String {
        let letters = text.filter { $0.isLetter }
        guard letters == "C", text.count <= 4 else { return text }
        return text.replacingOccurrences(of: "C", with: "Sí")
    }

    /// The next pass for a take whose speech ends `speechEnd` seconds in, or nil when nothing was
    /// said after the confirmed words. WhisperKit decodes nothing from a clip of `minimumLength` or
    /// less (it starts no window in a clip's last `windowClipTime`): a short tail reopens the
    /// confirmed words before it, and a short take is read with silence after it.
    public mutating func pass(speechEnd: Float, minimumLength: Float) -> Pass? {
        guard speechEnd > confirmedEnd else { return nil }
        while speechEnd - confirmedEnd <= minimumLength, let last = confirmed.popLast() {
            pending.insert(last.text, at: 0)
            confirmedEnd = confirmed.last?.end ?? 0
        }
        // One loudness frame past the minimum, so WhisperKit opens its window.
        return Pass(start: confirmedEnd, end: max(speechEnd, confirmedEnd + minimumLength + Float(DictationSpeech.frameSeconds)))
    }

    /// The segments of a pass that started at `confirmedEnd`, over audio with `speech` seconds of
    /// speech (`DictationSpeech.speechSeconds`).
    public mutating func update(_ segments: [Segment], final: Bool, speech: Float = .infinity) {
        // A segment with no word in it ("." or "..." for a breath or a noise before speaking) is
        // not text: it put a period at the start of the take.
        let decoded = segments.filter {
            $0.text.contains { $0.isLetter || $0.isNumber }
                && !(speech < Self.silencePhraseSpeech && Self.isSilencePhrase($0.text))
        }
        // Nothing decoded (Whisper judged it silent): the words already shown stay, and on the
        // final pass they are the take's last words.
        guard !decoded.isEmpty else { return }
        for segment in decoded { lowercaseWords.formUnion(Self.lowercaseWords(in: segment.text)) }
        var previous = confirmed.last?.text
        let segments = decoded.map { segment in
            defer { previous = segment.text }
            return Segment(text: continuing(segment.text, after: previous), start: segment.start, end: segment.end)
        }
        let settled = final ? segments.count : max(0, segments.count - Self.openSegments)
        let done = segments.prefix(settled)
        if let last = done.last, final || last.end > confirmedEnd {
            confirmed += done
            confirmedEnd = max(confirmedEnd, last.end)
        }
        pending = segments.dropFirst(settled).map(\.text)
    }

    /// `text` going on from `previous` mid-sentence: a first word Whisper capitalized only because
    /// a pass or segment starts there goes back to the lowercase it was written in elsewhere.
    private func continuing(_ text: String, after previous: String?) -> String {
        guard let previous = previous?.trimmingCharacters(in: .whitespaces), let last = previous.last,
              !".?!…".contains(last) else { return text }
        guard let range = text.range(of: #"\p{Lu}\p{Ll}*"#, options: .regularExpression),
              text[..<range.lowerBound].allSatisfy(\.isWhitespace) else { return text }
        let word = text[range].lowercased()
        guard lowercaseWords.contains(word) else { return text }
        return text.replacingCharacters(in: range, with: word)
    }

    private static func lowercaseWords(in text: String) -> [String] {
        text.split { !$0.isLetter }.map(String.init).filter { $0.first?.isLowercase == true }
    }

    /// Less speech than this in a pass, and a phrase Whisper writes for silence is that, not words:
    /// "gracias" said for real is half a second or more.
    static let silencePhraseSpeech: Float = 0.5

    /// What Whisper writes for silence or noise, in Spanish and English (it says them with full
    /// confidence, `noSpeechProb` 0, so its own silence check doesn't catch them).
    private static let silencePhrases: Set<String> = [
        "gracias", "muchas gracias", "gracias por ver", "gracias por ver el video", "gracias por su atencion",
        "gracias por vernos", "hasta la proxima", "suscribete", "suscribete al canal", "musica",
        "subtitulos realizados por la comunidad de amara org", "subtitulado por la comunidad de amara org",
        "subtitulos por la comunidad de amara org",
        "thank you", "thanks for watching", "thank you for watching", "you", "bye",
    ]

    static func isSilencePhrase(_ text: String) -> Bool {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let words = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return silencePhrases.contains(String(words).split(separator: " ").joined(separator: " "))
    }
}

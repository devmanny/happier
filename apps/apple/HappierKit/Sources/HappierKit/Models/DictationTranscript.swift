/// The text of one live dictation. The speech recognizer reports the current utterance as it grows,
/// but after a pause it starts a new one and reports only the new words: utterances already spoken
/// are kept here and the current one is appended, so a pause never erases what came before.
public struct DictationTranscript: Equatable, Sendable {
    /// Utterances already finished.
    private var spoken = ""
    /// What `spoken` was before the last utterance was added, in case the recognizer turns out to
    /// still be reporting that utterance (then it was not finished after all).
    private var spokenBeforeLast = ""
    private var lastUtterance = ""
    /// The utterance being recognized now.
    private var current = ""

    public init() {}

    public var text: String { Self.join(spoken, current) }

    /// A result from the recognizer: the current utterance's text so far, and whether the
    /// recognizer marked it finished (`speechRecognitionMetadata`, sent after a pause).
    public mutating func update(_ utterance: String, endsUtterance: Bool = false) {
        if current.isEmpty, !lastUtterance.isEmpty, utterance.hasPrefix(lastUtterance) {
            // Still the utterance just set aside: it continues rather than repeating.
            spoken = spokenBeforeLast
            lastUtterance = ""
        } else if Self.startsOver(from: current, to: utterance) {
            // A pause the recognizer didn't flag: the previous utterance is done.
            finish(current)
        }
        current = utterance
        if endsUtterance {
            finish(current)
            current = ""
        }
    }

    private mutating func finish(_ utterance: String) {
        guard !utterance.isEmpty else { return }
        spokenBeforeLast = spoken
        lastUtterance = utterance
        spoken = Self.join(spoken, utterance)
    }

    /// A new utterance, not a revision of the current one: much shorter, and not opening with the
    /// same word (a revision rewrites the end, or grows).
    private static func startsOver(from previous: String, to next: String) -> Bool {
        guard !previous.isEmpty, next.count * 2 < previous.count else { return false }
        return firstWord(next) != firstWord(previous)
    }

    private static func firstWord(_ text: String) -> Substring {
        text.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).first ?? ""
    }

    private static func join(_ a: String, _ b: String) -> String {
        a.isEmpty ? b : b.isEmpty ? a : a + " " + b
    }
}

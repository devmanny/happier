import Foundation

/// TL;DR for long agent messages, written on the device by Apple's on-device model (no tokens of
/// the user's accounts): which messages offer it, and what the model is told and given.
public enum MessageSummary {
    /// More than this many paragraphs (parted by a blank line) offers a TL;DR…
    static let maxParagraphs = 2
    /// …and so does one block longer than this, with no paragraphs to count.
    static let maxCharacters = 700

    public static func isLong(_ text: String) -> Bool {
        let paragraphs = text.components(separatedBy: "\n")
            .split { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
        return paragraphs > maxParagraphs || text.count > maxCharacters
    }

    /// The on-device model reads 4,096 tokens in all, instructions and its answer included; this much
    /// text (about three characters a token in Spanish) leaves room for both. A longer message is
    /// summarized from its beginning, marked as cut.
    public static let maxInputCharacters = 9_000

    public static func input(_ text: String) -> String {
        text.count <= maxInputCharacters ? text : String(text.prefix(maxInputCharacters)) + "\n\n[…]"
    }

    public static let instructions = """
    You write the TL;DR of a message an AI agent sent its user. Answer in the message's own language, \
    in two or three short sentences or up to four short bullet points: what was done or found, what \
    is left, and anything the user must decide or do. Keep names, numbers and file names exact. \
    No preamble, no heading, nothing that isn't in the message.
    """
}

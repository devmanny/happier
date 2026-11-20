import Foundation

/// Composer text with file mentions in it, the way the official composer writes them
/// (`composerSuggestionGrammar.ts`): a token starts at the beginning or after whitespace, is
/// `@path` or `@"path"` (quotes doubled inside), and runs to the next boundary character.
public enum MentionText {
    public enum Segment: Equatable, Sendable {
        case text(String)
        case mention(String)
    }

    /// Splits text into plain runs and file mentions. A bare `@word` counts as a file when it looks
    /// like one (a path, or a name with an extension) or is one of `known`, so `@claude` and
    /// e-mail addresses stay text.
    public static func segments(in text: String, known: Set<String> = []) -> [Segment] {
        var segments: [Segment] = []
        var plain = ""
        let chars = Array(text)
        func flush() {
            if !plain.isEmpty { segments.append(.text(plain)) }
            plain = ""
        }
        var i = 0
        while i < chars.count {
            let startsToken = chars[i] == "@" && (i == 0 || chars[i - 1].isWhitespace) && i + 1 < chars.count
            if startsToken, chars[i + 1] == "\"" {
                var j = i + 2
                var value = ""
                var closed = false
                while j < chars.count {
                    if chars[j] == "\"" {
                        if j + 1 < chars.count, chars[j + 1] == "\"" {
                            value.append("\"")
                            j += 2
                            continue
                        }
                        closed = true
                        j += 1
                        break
                    }
                    value.append(chars[j])
                    j += 1
                }
                if closed, !value.isEmpty, !value.contains("\n") {
                    flush()
                    segments.append(.mention(value))
                    i = j
                    continue
                }
            } else if startsToken {
                var j = i + 1
                while j < chars.count, !FileMention.boundaries.contains(chars[j]) { j += 1 }
                var value = String(chars[(i + 1)..<j])
                var trailing = ""
                while let last = value.last, sentencePunctuation.contains(last) {
                    trailing = String(last) + trailing
                    value.removeLast()
                }
                if !value.isEmpty, known.contains(value) || looksLikeFile(value) {
                    flush()
                    segments.append(.mention(value))
                    plain = trailing
                    i = j
                    continue
                }
            }
            plain.append(chars[i])
            i += 1
        }
        flush()
        return segments
    }

    /// Back to text, with each mention as a token that reads back as the same mention: a space
    /// goes in where a neighbour would otherwise run into it.
    public static func string(from segments: [Segment]) -> String {
        var out = ""
        var afterBareMention = false
        for segment in segments {
            switch segment {
            case .text(let text):
                if afterBareMention, let first = text.first, !first.isWhitespace,
                   !FileMention.boundaries.contains(first), !sentencePunctuation.contains(first) {
                    out += " "
                }
                out += text
                afterBareMention = false
            case .mention(let path):
                if let last = out.last, !last.isWhitespace { out += " " }
                let token = FileMention.token(path)
                out += token
                afterBareMention = !token.hasPrefix("@\"")
            }
        }
        return out
    }

    /// The `@word` being typed right before the cursor (UTF-16 `caret` in `text`), for file
    /// suggestions: where it is and what follows the `@`. Nil unless the word starts with `@` at
    /// the beginning, after whitespace or after a pill.
    public static func typingQuery(in text: NSString, caret: Int) -> (range: NSRange, query: String)? {
        guard caret <= text.length else { return nil }
        var start = caret
        while start > 0 {
            let unit = text.character(at: start - 1)
            if unit == 0xFFFC || CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(unit) ?? " ") { break }
            start -= 1
        }
        guard start < caret, text.character(at: start) == 0x40 else { return nil }
        let range = NSRange(location: start, length: caret - start)
        let query = text.substring(with: NSRange(location: start + 1, length: caret - start - 1))
        guard !query.contains("\"") else { return nil }
        return (range, query)
    }

    private static let sentencePunctuation: Set<Character> = [".", ",", ":", ";"]

    /// A path, or a single name with a short extension.
    static func looksLikeFile(_ value: String) -> Bool {
        if value.contains("/") { return true }
        guard let dot = value.lastIndex(of: "."), dot != value.startIndex else { return false }
        let ext = value[value.index(after: dot)...]
        return (1...10).contains(ext.count) && ext.allSatisfy { $0.isLetter || $0.isNumber }
    }
}

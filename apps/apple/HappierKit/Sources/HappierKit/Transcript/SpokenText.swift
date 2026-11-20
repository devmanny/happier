import Foundation
import NaturalLanguage

/// The text a "Speak" action reads aloud: what the bubble shows, without Markdown syntax. Code
/// blocks and reply options are skipped; table rows are read as "Header: value." pairs.
public enum SpokenText {
    public static func from(markdown: String) -> String {
        from(segments: MarkdownSegments.parse(markdown))
    }

    /// The same text in sentences, the steps "back" and "forward" move between. Every line is
    /// its own step too (a heading, a list item).
    public static func sentences(markdown: String) -> [String] {
        from(markdown: markdown).split(separator: "\n").flatMap { line -> [String] in
            let line = String(line)
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = line
            return tokenizer.tokens(for: line.startIndex..<line.endIndex)
                .map { line[$0].trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }

    private static func from(segments: [MarkdownSegments.Segment]) -> String {
        var parts: [String] = []
        for segment in segments {
            switch segment {
            case .prose(let text):
                let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { plain(String($0)) }
                parts.append(contentsOf: lines.filter { !$0.isEmpty })
            case .table(let table):
                for row in table.rows {
                    let pairs = zip(table.headers, row).compactMap { header, cell -> String? in
                        let value = plain(cell)
                        return value.isEmpty ? nil : "\(plain(header)): \(value)."
                    }
                    if !pairs.isEmpty { parts.append(pairs.joined(separator: " ")) }
                }
            case .quote(let inner):
                let text = from(segments: inner)
                if !text.isEmpty { parts.append(text) }
            case .code, .options:
                continue
            }
        }
        return parts.joined(separator: "\n")
    }

    /// One line of inline Markdown as plain text (headings, list markers, emphasis, code, links).
    private static func plain(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        if let range = text.range(of: #"^(#{1,6}|[-*+]|\d+[.)])\s+"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            text = String(attributed.characters)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

/// Reading speed as a multiple of the voice's normal pace.
public enum SpeechRate {
    /// Fine steps around the normal pace, where small changes are easy to hear.
    public static let steps: [Double] = [0.75, 0.9, 1, 1.1, 1.2, 1.3, 1.5, 2]
    public static let normal = 1.0

    public static func faster(_ rate: Double) -> Double { steps.first { $0 > rate + 0.001 } ?? steps.last! }
    public static func slower(_ rate: Double) -> Double { steps.last { $0 < rate - 0.001 } ?? steps.first! }

    /// "1.25×", "2×".
    public static func label(_ rate: Double) -> String {
        "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
    }
}

import Foundation

/// The text a "Speak" action reads aloud: what the bubble shows, without Markdown syntax. Code
/// blocks and reply options are skipped; table rows are read as "Header: value." pairs.
public enum SpokenText {
    public static func from(markdown: String) -> String {
        var parts: [String] = []
        for segment in MarkdownSegments.parse(markdown) {
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

import HappierKit
import SwiftUI

/// Lightweight Markdown for chat bubbles: inline styling via `AttributedString`, fenced code
/// blocks rendered as monospaced panels, GFM tables, and `#` headings as bold lines. Block
/// splitting is owned by `MarkdownSegments`.
struct MarkdownText: View {
    let segments: [MarkdownSegments.Segment]

    init(_ source: String) {
        segments = MarkdownSegments.parse(source)
    }

    init(segments: [MarkdownSegments.Segment]) {
        self.segments = segments
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let text):
                    Text(Self.attributed(text))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let code):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                case .table(let table):
                    MarkdownTableView(table: table)
                case .options(let items):
                    ForEach(items, id: \.self) { Text("• \($0)") }
                }
            }
        }
    }

    static func attributed(_ text: String) -> AttributedString {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.drop { $0 == "#" }
            if trimmed.count < line.count, trimmed.first == " " {
                return "**\(trimmed.dropFirst())**"
            }
            return String(line)
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: lines.joined(separator: "\n"), options: options)) ?? AttributedString(text)
    }
}

/// A GFM table sized to the bubble: columns share the width and long cells wrap, with a bold
/// header row and hairline row separators.
private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
            GridRow {
                ForEach(table.headers.indices, id: \.self) { column in
                    cell(table.headers[column], column: column).fontWeight(.semibold)
                }
            }
            ForEach(table.rows.indices, id: \.self) { row in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(table.headers.indices, id: \.self) { column in
                        cell(column < table.rows[row].count ? table.rows[row][column] : "", column: column)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .textSelection(.enabled)
    }

    private func cell(_ text: String, column: Int) -> some View {
        let alignment: Alignment = switch table.alignments[column] {
        case .center: .center
        case .trailing: .trailing
        case .default, .leading: .leading
        }
        return Text(MarkdownText.attributed(text))
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: alignment)
            .padding(.vertical, 6)
    }
}

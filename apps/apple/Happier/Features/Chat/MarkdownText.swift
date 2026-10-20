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

/// A GFM table as a rounded card: a bold header band, row separators, and columns sized to their
/// content (wrapping past `maxColumnWidth`). A table wider than the bubble scrolls inside the card,
/// with an inner shadow on the edge where more columns continue underneath.
private struct MarkdownTableView: View {
    let table: MarkdownTable
    @Environment(\.colorScheme) private var colorScheme
    @State private var offset: CGFloat = 0
    @State private var visibleWidth: CGFloat = 0
    @State private var headerHeight: CGFloat = 0

    private static let maxColumnWidth: CGFloat = 240
    private static let minColumnWidth: CGFloat = 48
    private static let cellPadding: CGFloat = 10
    private static let corner: CGFloat = 12
    private static let shadowWidth: CGFloat = 28

    var body: some View {
        let widths = columnWidths()
        let total = widths.reduce(0, +)
        // Known up front (no scrolling needed): more columns hide past either edge.
        let moreTrailing = visibleWidth > 0 && offset + visibleWidth < total - 1
        let moreLeading = offset > 1
        ScrollView(.horizontal, showsIndicators: false) {
            grid(widths)
                // Natural size: rows as tall as their content, columns as wide as computed.
                .fixedSize()
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, new in offset = new }
        // Columns fade as they slide under an edge that hides more of the table.
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(moreLeading ? 0.15 : 1), .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.shadowWidth)
                Rectangle()
                LinearGradient(colors: [.black, .black.opacity(moreTrailing ? 0.15 : 1)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.shadowWidth)
            }
        }
        // The card is never wider than the table; a wider table scrolls inside it.
        .frame(maxWidth: total, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { visibleWidth = $0 }
        .background(Color.black.opacity(colorScheme == .dark ? 0.28 : 0.05))
        .overlay(alignment: .trailing) { if moreTrailing { edgeShadow(.trailing) } }
        .overlay(alignment: .leading) { if moreLeading { edgeShadow(.leading) } }
        .animation(.easeOut(duration: 0.15), value: moreTrailing)
        .animation(.easeOut(duration: 0.15), value: moreLeading)
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1))
        .textSelection(.enabled)
    }

    private func grid(_ widths: [CGFloat]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(table.headers.indices, id: \.self) { column in
                    cell(table.headers[column], column: column, width: widths[column])
                        .fontWeight(.bold)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = max(headerHeight, $0) }
                }
            }
            ForEach(table.rows.indices, id: \.self) { row in
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(height: 1)
                    .gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(table.headers.indices, id: \.self) { column in
                        cell(column < table.rows[row].count ? table.rows[row][column] : "", column: column, width: widths[column])
                    }
                }
            }
        }
        // One header band behind the whole first row (per-cell fills left seams between columns).
        .background(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: headerHeight)
        }
    }

    /// Inner shadow cast by the card's edge onto the columns sliding under it.
    private func edgeShadow(_ edge: HorizontalEdge) -> some View {
        Rectangle()
            .fill(.black.opacity(colorScheme == .dark ? 1 : 0.4))
            .frame(width: 10)
            .blur(radius: 6)
            .offset(x: edge == .trailing ? 4 : -4)
            .frame(width: Self.shadowWidth, alignment: edge == .trailing ? .trailing : .leading)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    private func cell(_ text: String, column: Int, width: CGFloat) -> some View {
        let alignment: Alignment = switch table.alignments[column] {
        case .center: .center
        case .trailing: .trailing
        case .default, .leading: .leading
        }
        return Text(MarkdownText.attributed(text))
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width - 2 * Self.cellPadding, alignment: alignment)
            .padding(.horizontal, Self.cellPadding)
            .padding(.vertical, 8)
            .frame(maxHeight: .infinity, alignment: .center)
    }

    /// Each column as wide as its longest cell on one line, clamped; text wraps beyond the cap.
    private func columnWidths() -> [CGFloat] {
        table.headers.indices.map { column in
            let cells = [(table.headers[column], true)] + table.rows.map { (column < $0.count ? $0[column] : "", false) }
            let natural = cells.map { Self.lineWidth(MarkdownText.attributed($0.0), bold: $0.1) }.max() ?? 0
            return min(Self.maxColumnWidth, max(Self.minColumnWidth, ceil(natural) + 2 * Self.cellPadding + 4))
        }
    }

    /// One-line width with the fonts each run renders in (inline code is monospaced, ** is bold).
    private static func lineWidth(_ text: AttributedString, bold: Bool) -> CGFloat {
        #if os(iOS)
        let size = UIFont.preferredFont(forTextStyle: .callout).pointSize
        func font(code: Bool, strong: Bool) -> UIFont {
            code ? .monospacedSystemFont(ofSize: size, weight: strong ? .bold : .regular)
                : .systemFont(ofSize: size, weight: strong ? .bold : .regular)
        }
        #else
        let size = NSFont.preferredFont(forTextStyle: .callout).pointSize
        func font(code: Bool, strong: Bool) -> NSFont {
            code ? .monospacedSystemFont(ofSize: size, weight: strong ? .bold : .regular)
                : .systemFont(ofSize: size, weight: strong ? .bold : .regular)
        }
        #endif
        return text.runs.reduce(0) { width, run in
            let intent = run.inlinePresentationIntent ?? []
            let piece = String(text[run.range].characters) as NSString
            let runFont = font(code: intent.contains(.code), strong: bold || intent.contains(.stronglyEmphasized))
            return width + piece.size(withAttributes: [.font: runFont]).width
        }
    }
}

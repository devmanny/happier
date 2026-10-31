import HappierKit
import SwiftUI

/// Lightweight Markdown for chat bubbles: inline styling via `AttributedString`, fenced code
/// blocks rendered as monospaced panels, GFM tables, and `#` headings as bold lines. Block
/// splitting is owned by `MarkdownSegments`.
struct MarkdownText: View {
    let segments: [MarkdownSegments.Segment]
    /// Off unless the message's "Select Text" is on (the Mac selected by default, unasked).
    @Environment(\.messageTextSelectable) private var selectable

    init(_ source: String) {
        segments = MarkdownSegments.cached(source)
    }

    init(segments: [MarkdownSegments.Segment]) {
        self.segments = segments
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let text):
                    ProseView(text: text)
                case .code(let code, let language):
                    CodeBlockView(code: code, language: language)
                case .table(let table):
                    MarkdownTableView(table: table)
                case .quote(let inner):
                    // A bar down the side and the quoted Markdown, a step quieter than the text around it.
                    MarkdownText(segments: inner)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(.tertiary)
                                .frame(width: 3)
                        }
                case .options(let items):
                    ForEach(items, id: \.self) { Text("• \($0)") }
                }
            }
        }
    }

    /// Inline Markdown as styled text, remembered per text (built again on every redraw).
    static func attributed(_ text: String) -> AttributedString {
        attributedCache.value(for: text, make: parseInline)
    }

    private static let attributedCache = TextCache<AttributedString>()

    private static func parseInline(_ text: String) -> AttributedString {
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
    @Environment(\.messageTextSelectable) private var selectable
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
        .textSelectable(selectable)
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

/// Prose as it reads: headings at their size, list and task items with their marker and
/// indent, rules as a line, and runs of plain lines as one styled text (`MarkdownProse`).
private struct ProseView: View {
    let text: String
    @Environment(\.messageTextSelectable) private var selectable

    enum Block {
        case text(String)
        case line(MarkdownProse.Line)
    }

    var body: some View {
        let blocks = Self.blocks(text)
        if blocks.count == 1, case .text(let text) = blocks[0] {
            plain(text)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let text): plain(text)
                    case .line(let line): self.line(line)
                    }
                }
            }
        }
    }

    private func plain(_ text: String) -> some View {
        Text(MarkdownText.attributed(text))
            .textSelectable(selectable)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func line(_ line: MarkdownProse.Line) -> some View {
        switch line {
        case .heading(let level, let text):
            Text(MarkdownText.attributed(text))
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .textSelectable(selectable)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 2 ? 4 : 2)
                .accessibilityAddTraits(.isHeader)
        case .bullet(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).monospacedDigit().foregroundStyle(.secondary)
                plain(text)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .task(let indent, let done, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .foregroundStyle(done ? Color.green : Color.secondary)
                    .accessibilityLabel(done ? Text("Done") : Text("Not done"))
                plain(text).foregroundStyle(done ? .secondary : .primary)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .rule:
            Divider().padding(.vertical, 4)
        case .text(let text):
            plain(text)
        }
    }

    /// Runs of plain lines stay one text (selection and line spacing as before); the rest stand alone.
    static func blocks(_ text: String) -> [Block] {
        blockCache.value(for: text) { text in
            var blocks: [Block] = []
            var run: [String] = []
            func flush() {
                let joined = run.joined(separator: "\n").trimmingCharacters(in: .newlines)
                if !joined.isEmpty { blocks.append(.text(joined)) }
                run = []
            }
            for line in MarkdownProse.lines(text) {
                if case .text(let plain) = line { run.append(plain) } else { flush(); blocks.append(.line(line)) }
            }
            flush()
            return blocks
        }
    }

    private static let blockCache = TextCache<[Block]>()
}

/// A fenced code block: highlighted for its language (a diff in its colours), scrolling sideways
/// when wide, with a copy button in its corner that turns into a check for a moment once copied.
private struct CodeBlockView: View {
    let code: String
    var language: String? = nil
    @Environment(\.messageTextSelectable) private var selectable
    @State private var copied = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                if let language {
                    Text(language)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(Self.highlighted(code, language: language))
                    .font(.callout.monospaced())
                    .textSelectable(selectable)
            }
            .padding(10)
            // Room for the copy button over the first line.
            .padding(.trailing, 28)
        }
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button {
                MessageClipboard.copy(code)
                withAnimation(.smooth(duration: 0.2)) { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation(.smooth(duration: 0.2)) { copied = false }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(copied ? Color.green : Color.primary.opacity(0.75))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28, height: 28)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .focusEffectDisabled()
            .padding(5)
            .sensoryFeedback(.success, trigger: copied) { _, now in now }
            .accessibilityLabel(copied ? Text("Copied") : Text("Copy code"))
        }
    }
}

extension CodeBlockView {
    /// The code with its tokens coloured, remembered per language and text.
    static func highlighted(_ code: String, language: String?) -> AttributedString {
        highlightCache.value(for: "\(language ?? "")\u{0}\(code)") { _ in
            var text = AttributedString(code)
            switch language?.lowercased() {
            case "diff", "patch":
                var offset = 0
                for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
                    let color: Color? = line.hasPrefix("+") && !line.hasPrefix("+++") ? .green
                        : line.hasPrefix("-") && !line.hasPrefix("---") ? .red
                        : line.hasPrefix("@@") ? .blue : nil
                    if let color, let range = text.range(offset: offset, length: line.count) { text[range].foregroundColor = color }
                    offset += line.count + 1
                }
            default:
                for token in SyntaxHighlighter.tokens(code, language: language) {
                    guard let lower = AttributedString.Index(token.range.lowerBound, within: text),
                          let upper = AttributedString.Index(token.range.upperBound, within: text) else { continue }
                    text[lower..<upper].foregroundColor = switch token.kind {
                    case .keyword: Color.pink
                    case .string: Color.orange
                    case .comment: Color.gray
                    case .number: Color.blue
                    case .property: Color.teal
                    }
                }
            }
            return text
        }
    }

    private static let highlightCache = TextCache<AttributedString>()
}

private extension AttributedString {
    /// The range covering `length` characters from `offset`, when the text has them.
    func range(offset: Int, length: Int) -> Range<AttributedString.Index>? {
        guard length > 0, offset + length <= characters.count else { return nil }
        let start = characters.index(characters.startIndex, offsetBy: offset)
        return start..<characters.index(start, offsetBy: length)
    }
}

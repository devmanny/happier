import Foundation

/// A passive, self-contained reading copy. The original Markdown remains the shareable file.
/// Block grammar belongs to MarkdownSegments and Foundation; only their presentation is HTML.
public enum MarkdownFilePreview {
    public static func supports(_ url: URL) -> Bool {
        ["md", "markdown"].contains(url.pathExtension.lowercased())
    }

    public static func html(markdown: String, title: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <title>\(escape(title))</title>
        <style>
        :root { color-scheme: light dark; }
        * { box-sizing: border-box; }
        body { margin: 0 auto; padding: 24px 20px 48px; max-width: 960px;
          font: 17px/1.6 -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
          background: Canvas; color: CanvasText; overflow-wrap: anywhere; }
        h1,h2,h3,h4,h5,h6 { line-height: 1.25; margin: 1.4em 0 .6em; }
        h1 { font-size: 2em; } h2 { font-size: 1.6em; } h3 { font-size: 1.3em; }
        h4,h5,h6 { font-size: 1.1em; }
        p { margin: .8em 0; } a { color: LinkText; }
        ul,ol { padding-inline-start: 1.6em; } li > p { margin: .3em 0; }
        blockquote { margin: 1em 0; padding-inline-start: 1em;
          border-inline-start: 3px solid GrayText; color: GrayText; }
        code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .9em; }
        pre { padding: 14px; overflow-x: auto; white-space: pre; overflow-wrap: normal;
          background: color-mix(in srgb, CanvasText 6%, Canvas); border-radius: 10px; }
        .table-scroll { max-width: 100%; overflow-x: auto; margin: 1em 0; }
        table { border-collapse: collapse; min-width: 100%; }
        th,td { text-align: left; padding: 9px 12px; vertical-align: top;
          border: 1px solid color-mix(in srgb, CanvasText 20%, Canvas); }
        th { background: color-mix(in srgb, CanvasText 7%, Canvas); }
        .align-center { text-align: center; } .align-trailing { text-align: right; }
        </style></head><body>
        \(render(MarkdownSegments.parse(markdown)))
        </body></html>
        """
    }

    private static func render(_ segments: [MarkdownSegments.Segment]) -> String {
        segments.map { segment in
            switch segment {
            case .prose(let source): prose(source)
            case .code(let source, _): "<pre><code>\(escape(source))</code></pre>"
            case .quote(let children): "<blockquote>\(render(children))</blockquote>"
            case .options(let items): "<ul>" + items.map { "<li>\(inline($0))</li>" }.joined() + "</ul>"
            case .table(let table):
                "<div class=\"table-scroll\"><table><thead><tr>"
                    + table.headers.enumerated().map { cell($0.element, tag: "th", column: $0.offset, table: table) }.joined()
                    + "</tr></thead><tbody>"
                    + table.rows.map { row in
                        "<tr>" + row.enumerated().map { cell($0.element, tag: "td", column: $0.offset, table: table) }.joined() + "</tr>"
                    }.joined() + "</tbody></table></div>"
            }
        }.joined(separator: "\n")
    }

    private struct Block {
        let id: Int
        let opening: String
        let closing: String
    }

    /// Foundation supplies nested block identities, including list items and their ordinals.
    /// Keeping the common ancestor open preserves nested lists without parsing Markdown again.
    private static func prose(_ source: String) -> String {
        guard let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full)) else {
            return "<p>\(escape(source))</p>"
        }
        var html = ""
        var open: [Block] = []
        for run in parsed.runs {
            let components = run.presentationIntent.map { Array($0.components.reversed()) } ?? []
            let blocks = components.enumerated().map { index, component -> Block in
                let tags: (String, String)
                switch component.kind {
                case .paragraph: tags = ("<p>", "</p>")
                case .header(let level): tags = ("<h\(level)>", "</h\(level)>")
                case .unorderedList: tags = ("<ul>", "</ul>")
                case .orderedList:
                    let ordinal = components.dropFirst(index + 1).compactMap { child -> Int? in
                        if case .listItem(let ordinal) = child.kind { return ordinal }
                        return nil
                    }.first ?? 1
                    tags = (ordinal == 1 ? "<ol>" : "<ol start=\"\(ordinal)\">", "</ol>")
                case .listItem: tags = ("<li>", "</li>")
                case .blockQuote: tags = ("<blockquote>", "</blockquote>")
                case .codeBlock: tags = ("<pre><code>", "</code></pre>")
                case .thematicBreak: tags = ("<hr>", "")
                default: tags = ("<div>", "</div>")
                }
                return Block(id: component.identity, opening: tags.0, closing: tags.1)
            }
            let shared = zip(open, blocks).prefix { $0.id == $1.id }.count
            html += open.dropFirst(shared).reversed().map(\.closing).joined()
            html += blocks.dropFirst(shared).map(\.opening).joined()
            open = blocks
            let isRule = components.contains { if case .thematicBreak = $0.kind { true } else { false } }
            if !isRule { html += inline(AttributedString(parsed[run.range])) }
        }
        return html + open.reversed().map(\.closing).joined()
    }

    private static func cell(_ source: String, tag: String, column: Int, table: MarkdownTable) -> String {
        let alignment = column < table.alignments.count ? table.alignments[column] : .default
        let attribute = switch alignment {
        case .center: " class=\"align-center\""
        case .trailing: " class=\"align-trailing\""
        case .default, .leading: ""
        }
        return "<\(tag)\(attribute)>\(inline(source))</\(tag)>"
    }

    private static func inline(_ source: String) -> String {
        guard let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return escape(source)
        }
        return inline(parsed)
    }

    private static func inline(_ parsed: AttributedString) -> String {
        parsed.runs.map { run in
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.lineBreak) { return "<br>" }
            var content = escape(String(parsed[run.range].characters))
            if intent.contains(.code) { content = "<code>\(content)</code>" }
            if intent.contains(.stronglyEmphasized) { content = "<strong>\(content)</strong>" }
            if intent.contains(.emphasized) { content = "<em>\(content)</em>" }
            if intent.contains(.strikethrough) { content = "<del>\(content)</del>" }
            if let link = run.link, let href = safeLink(link) {
                content = "<a href=\"\(escape(href))\">\(content)</a>"
            }
            return content
        }.joined()
    }

    private static func safeLink(_ url: URL) -> String? {
        let value = url.absoluteString
        if url.scheme == nil, value.hasPrefix("#") { return value }
        guard let scheme = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme) else { return nil }
        return value
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

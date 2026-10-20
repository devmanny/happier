import Foundation

/// A GFM table; cells keep their inline Markdown.
public struct MarkdownTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable { case `default`, leading, center, trailing }

    public let headers: [String]
    public let rows: [[String]]
    public let alignments: [Alignment]

    public init(headers: [String], rows: [[String]], alignments: [Alignment]) {
        self.headers = headers
        self.rows = rows
        self.alignments = alignments
    }
}

/// Splits agent text into prose, fenced code, GFM tables and `<options>` reply suggestions,
/// following `parseMarkdownBlock.ts`. Tapping an option sends its text as a user message.
public enum MarkdownSegments {
    public enum Segment: Equatable, Sendable {
        case prose(String)
        case code(String)
        case table(MarkdownTable)
        case options([String])
    }

    public static func parse(_ source: String) -> [Segment] {
        var segments: [Segment] = []
        var prose: [Substring] = []
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.isEmpty { segments.append(.prose(text)) }
            prose = []
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            index += 1

            if trimmed.hasPrefix("```") {
                flushProse()
                var code: [Substring] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                segments.append(.code(code.joined(separator: "\n")))
                continue
            }

            if trimmed.contains("|"), let (table, next) = table(in: lines, from: index - 1) {
                flushProse()
                segments.append(.table(table))
                index = next
                continue
            }

            let wrapped = trimmed.hasPrefix("<options>")
            let first = option(in: line)
            if wrapped || first != nil {
                flushProse()
                var items = first.map { [$0] } ?? []
                while index < lines.count {
                    let next = lines[index]
                    if next.trimmingCharacters(in: .whitespaces) == "</options>" {
                        index += 1
                        break
                    }
                    if let item = option(in: next) {
                        items.append(item)
                    } else if !wrapped {
                        break
                    }
                    index += 1
                }
                if !items.isEmpty { segments.append(.options(items)) }
                continue
            }

            prose.append(line)
        }
        flushProse()
        return segments
    }

    /// `parseTable`: consecutive lines with pipes whose second line is a `|---|` separator.
    private static func table(in lines: [Substring], from start: Int) -> (MarkdownTable, Int)? {
        var end = start
        while end < lines.count, lines[end].contains("|") { end += 1 }
        guard end - start >= 2 else { return nil }
        let separator = lines[start + 1].trimmingCharacters(in: .whitespaces)
        guard separator.contains("-"), separator.allSatisfy({ "|-:= \t".contains($0) }) else { return nil }
        let headers = cells(lines[start])
        guard !headers.isEmpty else { return nil }
        let separatorCells = cells(lines[start + 1][...])
        let alignments = headers.indices.map { column -> MarkdownTable.Alignment in
            let cell = column < separatorCells.count ? separatorCells[column] : ""
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): return .center
            case (true, false): return .leading
            case (false, true): return .trailing
            case (false, false): return .default
            }
        }
        let rows = lines[(start + 2)..<end]
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("|") }
            .map { line -> [String] in
                var row = cells(line)
                while row.count < headers.count { row.append("") }
                return row
            }
        return (MarkdownTable(headers: headers, rows: rows, alignments: alignments), end)
    }

    /// GFM cells: `\|` is a literal pipe; leading/trailing pipe artifacts are dropped.
    private static func cells(_ line: Substring) -> [String] {
        var cells: [String] = []
        var current = ""
        var characters = line.trimmingCharacters(in: .whitespaces)[...]
        while let character = characters.popFirst() {
            if character == "\\", characters.first == "|" {
                current.append("|")
                characters.removeFirst()
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return cells
    }

    private static func option(in line: Substring) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<option>"), trimmed.hasSuffix("</option>"), trimmed.count >= 17 else { return nil }
        return String(trimmed.dropFirst(8).dropLast(9))
    }
}

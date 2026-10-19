import Foundation

/// Splits agent text into prose, fenced code and `<options>` reply suggestions, following
/// `parseMarkdownBlock.ts`. Tapping an option sends its text as a user message.
public enum MarkdownSegments {
    public enum Segment: Equatable, Sendable {
        case prose(String)
        case code(String)
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

    private static func option(in line: Substring) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<option>"), trimmed.hasSuffix("</option>"), trimmed.count >= 17 else { return nil }
        return String(trimmed.dropFirst(8).dropLast(9))
    }
}

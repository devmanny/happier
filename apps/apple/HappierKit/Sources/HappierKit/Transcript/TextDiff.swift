import Foundation

/// A line diff for a tool card: computed from an edit's old and new text, or read from a unified
/// diff or an `apply_patch` envelope. Unchanged stretches far from a change fold into a gap.
public struct TextDiff: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case context, added, removed
        /// A unified diff's `@@ … @@` line; `text` is what follows it.
        case hunk
        /// Unchanged lines left out between two changes.
        case gap
    }

    public struct Line: Sendable, Equatable, Identifiable {
        public let id: Int
        public let kind: Kind
        public let text: String
        public let oldNumber: Int?
        public let newNumber: Int?
    }

    /// One file of a multi-file diff; `path` is nil for a bare hunk.
    public struct File: Sendable, Equatable, Identifiable {
        public let path: String?
        public let diff: TextDiff
        public var isDeletion = false
        public var id: String { path ?? "" }
    }

    public let lines: [Line]
    public var added: Int { lines.count { $0.kind == .added } }
    public var removed: Int { lines.count { $0.kind == .removed } }

    init(lines: [Line]) {
        self.lines = lines
    }

    /// The change from `old` to `new`, with `context` unchanged lines around each change.
    public init(old: String, new: String, context: Int = 3) {
        let before = Self.split(old), after = Self.split(new)
        var removedOld = Set<Int>(), insertedNew = Set<Int>()
        for change in after.difference(from: before) {
            switch change {
            case .remove(let offset, _, _): removedOld.insert(offset)
            case .insert(let offset, _, _): insertedNew.insert(offset)
            }
        }
        var full: [(Kind, String, Int?, Int?)] = []
        var i = 0, j = 0
        while i < before.count || j < after.count {
            if i < before.count, removedOld.contains(i) {
                full.append((.removed, before[i], i + 1, nil)); i += 1
            } else if j < after.count, insertedNew.contains(j) {
                full.append((.added, after[j], nil, j + 1)); j += 1
            } else if i < before.count, j < after.count {
                full.append((.context, before[i], i + 1, j + 1)); i += 1; j += 1
            } else {
                break
            }
        }
        let changed = full.indices.filter { full[$0].0 != .context }
        var keep = Set<Int>()
        for index in changed { keep.formUnion(max(0, index - context)...min(full.count - 1, index + context)) }
        var lines: [Line] = []
        var previous: Int?
        for index in full.indices where keep.contains(index) {
            if let previous, index > previous + 1 { lines.append(Line(id: lines.count, kind: .gap, text: "", oldNumber: nil, newNumber: nil)) }
            let (kind, text, oldNumber, newNumber) = full[index]
            lines.append(Line(id: lines.count, kind: kind, text: text, oldNumber: oldNumber, newNumber: newNumber))
            previous = index
        }
        self.lines = lines
    }

    // MARK: Unified diffs (`git diff`, Codex `unified_diff`)

    public static func files(fromUnified text: String) -> [File] {
        var files: [File] = []
        var path: String?, oldPath: String?, deletion = false
        var lines: [Line] = []
        var started = false
        var oldLine = 0, newLine = 0, oldLeft = 0, newLeft = 0

        func flush() {
            if started || !lines.isEmpty { files.append(File(path: path ?? oldPath, diff: TextDiff(lines: lines), isDeletion: deletion)) }
            path = nil; oldPath = nil; deletion = false; lines = []; started = false
        }
        func append(_ kind: Kind, _ text: String, _ old: Int?, _ new: Int?) {
            lines.append(Line(id: lines.count, kind: kind, text: text, oldNumber: old, newNumber: new))
        }

        for raw in split(text) {
            let inHunk = oldLeft > 0 || newLeft > 0
            if inHunk, let first = raw.first, first == " " || first == "-" || first == "+" {
                let body = String(raw.dropFirst())
                switch first {
                case "-": append(.removed, body, oldLine, nil); oldLine += 1; oldLeft -= 1
                case "+": append(.added, body, nil, newLine); newLine += 1; newLeft -= 1
                default: append(.context, body, oldLine, newLine); oldLine += 1; newLine += 1; oldLeft -= 1; newLeft -= 1
                }
                continue
            }
            if inHunk, raw.isEmpty {
                append(.context, "", oldLine, newLine); oldLine += 1; newLine += 1; oldLeft -= 1; newLeft -= 1
                continue
            }
            if raw.hasPrefix("diff --git ") {
                flush()
                started = true
                path = raw.components(separatedBy: " b/").last
            } else if raw.hasPrefix("--- ") {
                if !lines.isEmpty { flush() }
                started = true
                oldPath = stripPrefix(String(raw.dropFirst(4)))
            } else if raw.hasPrefix("+++ ") {
                let target = stripPrefix(String(raw.dropFirst(4)))
                if target == nil { deletion = true } else { path = target }
            } else if raw.hasPrefix("@@"), let header = parseHunkHeader(raw) {
                started = true
                (oldLine, oldLeft, newLine, newLeft) = (header.oldStart, header.oldCount, header.newStart, header.newCount)
                append(.hunk, header.rest, nil, nil)
            }
        }
        flush()
        return files
    }

    /// `/dev/null` is no file; `a/` and `b/` prefixes go.
    private static func stripPrefix(_ value: String) -> String? {
        let path = value.split(separator: "\t").first.map(String.init) ?? value
        if path == "/dev/null" { return nil }
        if path.hasPrefix("a/") || path.hasPrefix("b/") { return String(path.dropFirst(2)) }
        return path
    }

    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, rest: String)? {
        guard let match = line.firstMatch(of: /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@ ?(.*)$/) else { return nil }
        return (Int(match.1) ?? 0, match.2.flatMap { Int($0) } ?? 1, Int(match.3) ?? 0, match.4.flatMap { Int($0) } ?? 1, String(match.5))
    }

    // MARK: Codex `apply_patch` envelopes

    public static func files(fromApplyPatch text: String) -> [File] {
        var files: [File] = []
        var path: String?, deletion = false
        var lines: [Line] = []

        func flush() {
            if let path { files.append(File(path: path, diff: TextDiff(lines: lines), isDeletion: deletion)) }
            path = nil; deletion = false; lines = []
        }
        func append(_ kind: Kind, _ text: String) {
            lines.append(Line(id: lines.count, kind: kind, text: text, oldNumber: nil, newNumber: nil))
        }

        for raw in split(text) {
            if let name = raw.removingPrefix("*** Update File: ") ?? raw.removingPrefix("*** Add File: ") {
                flush(); path = name
            } else if let name = raw.removingPrefix("*** Delete File: ") {
                flush(); path = name; deletion = true
            } else if let name = raw.removingPrefix("*** Move to: ") {
                path = name
            } else if raw.hasPrefix("***") {
                continue
            } else if raw.hasPrefix("@@") {
                append(.hunk, String(raw.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            } else if path != nil, let first = raw.first {
                switch first {
                case "+": append(.added, String(raw.dropFirst()))
                case "-": append(.removed, String(raw.dropFirst()))
                case " ": append(.context, String(raw.dropFirst()))
                default: append(.context, raw)
                }
            }
        }
        flush()
        return files
    }

    /// Lines of a text; an empty text has none, and a final newline doesn't add an empty line.
    static func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

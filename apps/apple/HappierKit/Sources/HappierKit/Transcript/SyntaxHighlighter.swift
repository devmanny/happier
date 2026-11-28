import Foundation

/// Light syntax highlighting for code blocks in chat: keywords, strings, comments, numbers and
/// JSON keys, by language family. A lexer, not a parser: good enough to read code at a glance,
/// with no dependency. Blocks past `maxLength` stay plain, so a pasted log can't stall a redraw.
public enum SyntaxHighlighter {
    public enum Kind: Sendable, Equatable { case keyword, string, comment, number, property }

    public struct Token: Sendable, Equatable {
        public let range: Range<String.Index>
        public let kind: Kind
    }

    public static let maxLength = 20_000

    struct Grammar {
        var keywords: Set<String> = []
        var lineComments: [String] = ["//"]
        var blockComment: (open: String, close: String)? = ("/*", "*/")
        var quotes: Set<Character> = ["\"", "'"]
        /// Strings followed by `:` are keys (JSON).
        var keys = false
    }

    public static func tokens(_ code: String, language: String?) -> [Token] {
        guard code.utf8.count <= maxLength, let grammar = grammar(for: language) else { return [] }
        var tokens: [Token] = []
        var i = code.startIndex
        let end = code.endIndex

        func atBoundary(_ index: String.Index) -> Bool {
            index == code.startIndex || !isIdentifier(code[code.index(before: index)])
        }

        scan: while i < end {
            let rest = code[i...]
            if let block = grammar.blockComment, rest.hasPrefix(block.open) {
                let close = code.range(of: block.close, range: code.index(i, offsetBy: block.open.count)..<end)?.upperBound ?? end
                tokens.append(Token(range: i..<close, kind: .comment))
                i = close
                continue
            }
            for marker in grammar.lineComments where rest.hasPrefix(marker) {
                // `#` only opens a comment where a word could start (`a#b` and `$#` are not comments).
                if marker == "#", i > code.startIndex, !code[code.index(before: i)].isWhitespace { break }
                let close = code[i...].firstIndex(of: "\n") ?? end
                tokens.append(Token(range: i..<close, kind: .comment))
                i = close
                continue scan
            }
            let character = code[i]
            if grammar.quotes.contains(character) {
                var j = code.index(after: i)
                while j < end, code[j] != character {
                    if code[j] == "\\" { j = code.index(after: j); if j == end { break } }
                    else if code[j] == "\n", character != "`" { break }
                    j = code.index(after: j)
                }
                let close = j < end && code[j] == character ? code.index(after: j) : j
                var kind = Kind.string
                if grammar.keys {
                    var k = close
                    while k < end, code[k] == " " || code[k] == "\t" { k = code.index(after: k) }
                    if k < end, code[k] == ":" { kind = .property }
                }
                tokens.append(Token(range: i..<close, kind: kind))
                i = close
                continue
            }
            if character.isASCII, character.isNumber, atBoundary(i) {
                var j = code.index(after: i)
                while j < end, code[j].isASCII, code[j].isHexDigit || "xXoObB._".contains(code[j]) { j = code.index(after: j) }
                tokens.append(Token(range: i..<j, kind: .number))
                i = j
                continue
            }
            if isIdentifierStart(character), atBoundary(i) {
                var j = code.index(after: i)
                while j < end, isIdentifier(code[j]) { j = code.index(after: j) }
                if grammar.keywords.contains(String(code[i..<j])) { tokens.append(Token(range: i..<j, kind: .keyword)) }
                i = j
                continue
            }
            i = code.index(after: i)
        }
        return tokens
    }

    private static func isIdentifierStart(_ c: Character) -> Bool { c == "_" || c == "$" || c.isLetter }
    private static func isIdentifier(_ c: Character) -> Bool { c == "_" || c == "$" || c.isLetter || c.isNumber }

    // MARK: Grammars

    /// Nil for languages shown without highlighting (diffs get their own colours).
    static func grammar(for language: String?) -> Grammar? {
        switch language?.lowercased() {
        case "diff", "patch", "text", "txt", "plain", "plaintext", "log", "output", "mermaid":
            return nil
        case "swift":
            return Grammar(keywords: words("""
                let var func if else guard return for in while repeat switch case default break continue struct class enum \
                protocol extension import init deinit self Self super nil true false throw throws try catch do async await \
                public private fileprivate internal open static final override mutating some any where as is defer inout \
                typealias associatedtype weak lazy actor nonisolated
                """), quotes: ["\""])
        case "js", "javascript", "jsx", "mjs", "cjs", "ts", "typescript", "tsx":
            return Grammar(keywords: words("""
                const let var function return if else for while do switch case default break continue new delete typeof \
                instanceof in of class extends super this null undefined true false import export from as async await try \
                catch finally throw yield interface type enum implements public private protected readonly static declare \
                namespace keyof void never unknown any satisfies
                """), quotes: ["\"", "'", "`"])
        case "python", "py":
            return Grammar(keywords: words("""
                def class return if elif else for while in not and or is None True False import from as with try except \
                finally raise pass break continue lambda yield global nonlocal async await assert del
                """), lineComments: ["#"], blockComment: nil)
        case "bash", "sh", "shell", "zsh", "console", "shellscript":
            return Grammar(keywords: words("""
                if then else elif fi for while until do done case esac in function return export local echo cd exit set \
                unset source alias readonly shift
                """), lineComments: ["#"], blockComment: nil)
        case "go", "golang":
            return Grammar(keywords: words("""
                package import func return if else for range switch case default break continue go defer chan select \
                struct interface map type var const nil true false
                """), quotes: ["\"", "'", "`"])
        case "rust", "rs":
            return Grammar(keywords: words("""
                fn let mut pub use mod struct enum impl trait for in if else match return loop while break continue self \
                Self super crate where as ref move async await dyn true false const static unsafe type
                """), quotes: ["\""])
        case "java", "kotlin", "kt", "c", "cpp", "c++", "cc", "h", "hpp", "objc", "objective-c", "m", "cs", "csharp", "dart", "scala":
            return Grammar(keywords: words("""
                class interface enum struct public private protected static final void int long double float char bool \
                boolean return if else for while do switch case default break continue new this super null nullptr true \
                false import package include namespace using try catch throw throws const val var fun override object \
                when is in typedef sizeof virtual template typename auto
                """))
        case "ruby", "rb":
            return Grammar(keywords: words("""
                def end class module if elsif else unless while until for in do return yield begin rescue ensure raise \
                nil true false self require attr_accessor and or not then case when
                """), lineComments: ["#"], blockComment: nil)
        case "json", "jsonc", "json5":
            return Grammar(keywords: ["true", "false", "null"], quotes: ["\""], keys: true)
        case "yaml", "yml", "toml", "ini":
            return Grammar(keywords: ["true", "false", "null", "yes", "no"], lineComments: ["#"], blockComment: nil)
        case "sql":
            return Grammar(keywords: words("""
                select from where insert into values update set delete create table alter drop index join left right inner \
                outer on and or not null is as group by order having limit offset distinct union primary key references \
                SELECT FROM WHERE INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE ALTER DROP INDEX JOIN LEFT RIGHT INNER \
                OUTER ON AND OR NOT NULL IS AS GROUP BY ORDER HAVING LIMIT OFFSET DISTINCT UNION PRIMARY KEY REFERENCES
                """), lineComments: ["--"])
        case "css", "scss", "less":
            return Grammar(keywords: ["important", "media", "import", "from", "to"])
        case "html", "xml", "svg", "vue":
            return Grammar(blockComment: ("<!--", "-->"))
        default:
            // Unknown or unnamed: strings, numbers and C-style comments only.
            return Grammar()
        }
    }

    private static func words(_ list: String) -> Set<String> {
        Set(list.split(whereSeparator: \.isWhitespace).map(String.init))
    }
}

/// How each line of a prose block reads: headings, list items, task items, rules, or text
/// (`parseMarkdownBlock.ts`). Inline styling stays with the renderer.
public enum MarkdownProse {
    public enum Line: Sendable, Equatable {
        case heading(level: Int, text: String)
        /// `marker` is "•" for unordered items and the number for ordered ones ("3.").
        case bullet(indent: Int, marker: String, text: String)
        case task(indent: Int, done: Bool, text: String)
        case rule
        case text(String)
    }

    public static func lines(_ prose: String) -> [Line] {
        LineReader.shared.lines(prose)
    }

    /// Reads prose line by line, remembering each line's result. A line reads the same wherever it
    /// is (`line` is a pure function of it), so a reply streaming in only reads its new lines
    /// instead of every line again on each update.
    public final class LineReader: @unchecked Sendable {
        public static let shared = LineReader()

        private let cache = TextCache<Line>(limit: 4_000)
        private let lock = NSLock()
        private var parsed = 0

        public init() {}

        /// Lines read for the first time (not remembered), for tests.
        public var parsedLineCount: Int { lock.withLock { parsed } }

        public func lines(_ prose: String) -> [Line] {
            prose.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
                cache.value(for: String(raw)) { text in
                    lock.withLock { parsed += 1 }
                    return MarkdownProse.line(text)
                }
            }
        }
    }

    static func line(_ raw: String) -> Line {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let match = trimmed.wholeMatch(of: /(#{1,6})\s+(.+?)\s*#*/) {
            return .heading(level: match.1.count, text: String(match.2))
        }
        if trimmed.count >= 3, trimmed.wholeMatch(of: /(?:-\s*){3,}|(?:\*\s*){3,}|(?:_\s*){3,}/) != nil {
            return .rule
        }
        let leading = raw.prefix { $0 == " " || $0 == "\t" }
        let indent = leading.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
        if let match = trimmed.wholeMatch(of: /[-*+]\s+\[([ xX])\]\s+(.*)/) {
            return .task(indent: indent, done: match.1 != " ", text: String(match.2))
        }
        if let match = trimmed.wholeMatch(of: /[-*+]\s+(.*)/) {
            return .bullet(indent: indent, marker: "•", text: String(match.1))
        }
        if let match = trimmed.wholeMatch(of: /(\d{1,9}[.)])\s+(.*)/) {
            return .bullet(indent: indent, marker: String(match.1), text: String(match.2))
        }
        return .text(raw)
    }
}

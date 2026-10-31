import Testing
@testable import HappierKit

/// Code languages, syntax highlighting and prose line kinds for the chat's Markdown.
@Suite struct MarkdownRenderingTests {
    @Test func fencesKeepTheirLanguage() {
        #expect(MarkdownSegments.parse("```swift\nlet a = 1\n```") == [.code("let a = 1", language: "swift")])
        #expect(MarkdownSegments.parse("```ts title=\"a.ts\"\nx\n```") == [.code("x", language: "ts")])
        #expect(MarkdownSegments.parse("```\nx\n```") == [.code("x")])
    }

    private func kinds(_ code: String, _ language: String?) -> [(String, SyntaxHighlighter.Kind)] {
        SyntaxHighlighter.tokens(code, language: language).map { (String(code[$0.range]), $0.kind) }
    }

    @Test func swiftKeywordsStringsCommentsAndNumbers() {
        let tokens = kinds("let name = \"Ana\" // greet\nreturn 42", "swift")
        #expect(tokens.map(\.0) == ["let", "\"Ana\"", "// greet", "return", "42"])
        #expect(tokens.map(\.1) == [.keyword, .string, .comment, .keyword, .number])
    }

    @Test func pythonAndShellUseHashComments() {
        #expect(kinds("def f(): # doc\n  return 'x'", "python").map(\.1) == [.keyword, .comment, .keyword, .string])
        #expect(kinds("if [ -f a ]; then echo \"hi\"; fi # end", "bash").map(\.1) == [.keyword, .keyword, .keyword, .string, .keyword, .comment])
    }

    @Test func blockCommentsAndEscapedQuotesStayWhole() {
        let tokens = kinds("/* a \"b\" */ const s = \"x\\\"y\"", "js")
        #expect(tokens.map(\.0) == ["/* a \"b\" */", "const", "\"x\\\"y\""])
    }

    @Test func jsonKeysAndLiterals() {
        let tokens = kinds(#"{"a": true, "b": 1.5, "c": null}"#, "json")
        #expect(tokens.map(\.1) == [.property, .keyword, .property, .number, .property, .keyword])
    }

    @Test func identifiersInsideWordsArentKeywords() {
        #expect(kinds("letter = format(x)", "swift").isEmpty)
    }

    @Test func diffAndHugeBlocksAreNotTokenized() {
        #expect(SyntaxHighlighter.tokens("+a\n-b", language: "diff").isEmpty)
        #expect(SyntaxHighlighter.tokens(String(repeating: "let a = 1\n", count: 5_000), language: "swift").isEmpty)
    }

    @Test func proseLinesKnowHeadingsListsTasksAndRules() {
        let lines = MarkdownProse.lines("# Title\n### Sub\n- one\n  * nested\n3. third\n- [ ] todo\n- [x] done\n---\nplain #hash")
        #expect(lines == [
            .heading(level: 1, text: "Title"),
            .heading(level: 3, text: "Sub"),
            .bullet(indent: 0, marker: "•", text: "one"),
            .bullet(indent: 1, marker: "•", text: "nested"),
            .bullet(indent: 0, marker: "3.", text: "third"),
            .task(indent: 0, done: false, text: "todo"),
            .task(indent: 0, done: true, text: "done"),
            .rule,
            .text("plain #hash"),
        ])
    }
}

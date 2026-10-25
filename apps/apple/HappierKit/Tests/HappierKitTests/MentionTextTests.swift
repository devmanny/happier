import Foundation
import Testing
@testable import HappierKit

@Suite struct MentionTextTests {
    @Test func findsFileMentionsAmongText() {
        let segments = MentionText.segments(in: #"Mira @src/app.ts y @"My Docs/a b.md", luego @claude o a@b.com"#)
        #expect(segments == [
            .text("Mira "), .mention("src/app.ts"), .text(" y "), .mention("My Docs/a b.md"),
            .text(", luego @claude o a@b.com"),
        ])
    }

    @Test func sentencePunctuationIsntPartOfThePath() {
        #expect(MentionText.segments(in: "Lee @README.md.") == [.text("Lee "), .mention("README.md"), .text(".")])
        #expect(MentionText.segments(in: "@Makefile", known: ["Makefile"]) == [.mention("Makefile")])
        #expect(MentionText.segments(in: "@Makefile") == [.text("@Makefile")])
    }

    @Test func writingBackKeepsTokensApartFromTheirNeighbours() {
        #expect(MentionText.string(from: [.text("hola"), .mention("a.swift"), .text("adiós")]) == "hola @a.swift adiós")
        #expect(MentionText.string(from: [.text("ver "), .mention("My Docs/a.md"), .text(" ya")]) == #"ver @"My Docs/a.md" ya"#)
        #expect(MentionText.string(from: [.mention("a.swift")]) == "@a.swift")
        let text = "Mira @src/app.ts y luego"
        #expect(MentionText.string(from: MentionText.segments(in: text)) == text)
    }

    @Test func longNamesKeepTheirStartAndExtension() {
        #expect(FileMention.displayName("Sources/HappierKit/Sync/HappierStore.swift") == "HappierStore.swift")
        let short = FileMention.displayName("docs/a_really_long_file_name_for_the_composer_tests.swift", limit: 24)
        #expect(short.count == 24)
        #expect(short.hasPrefix("a_really_l"))
        #expect(short.hasSuffix(".swift"))
        #expect(short.contains("…"))
        #expect(FileMention.displayName("src/components/") == "components/")
    }

    @Test func theTokenBeingTypedBeforeTheCursor() {
        let text = "mira @comp" as NSString
        let query = MentionText.typingQuery(in: text, caret: text.length)
        #expect(query?.query == "comp")
        #expect(query?.range == NSRange(location: 5, length: 5))
        #expect(MentionText.typingQuery(in: "mira @" as NSString, caret: 6)?.query == "")
        #expect(MentionText.typingQuery(in: "a@b.com" as NSString, caret: 7) == nil)
        #expect(MentionText.typingQuery(in: "mira @comp y" as NSString, caret: 12) == nil)
        // A pill (attachment character) right before isn't part of a word.
        #expect(MentionText.typingQuery(in: "\u{FFFC}@src" as NSString, caret: 5)?.query == "src")
        // Up to the cursor only.
        #expect(MentionText.typingQuery(in: "@composer" as NSString, caret: 4)?.query == "com")
    }
}

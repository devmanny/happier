import Testing
@testable import HappierKit

/// TL;DR on long agent messages: which ones offer it, and what the on-device model is given.
@Suite struct MessageSummaryTests {
    @Test func onlyMessagesOfMoreThanTwoParagraphsOrAVeryLongOneOfferATLDR() {
        #expect(!MessageSummary.isLong("Listo, quedó."))
        #expect(!MessageSummary.isLong("Primer párrafo.\n\nSegundo párrafo."))
        #expect(MessageSummary.isLong("Uno.\n\nDos.\n\nTres."))
        // Blank lines made of spaces still part paragraphs; a single line break does not.
        #expect(MessageSummary.isLong("Uno.\n  \nDos.\n\t\nTres."))
        #expect(!MessageSummary.isLong("Uno.\nDos.\nTres."))
        // One wall of text with no paragraphs at all is long too.
        #expect(MessageSummary.isLong(String(repeating: "palabra ", count: 100)))
        #expect(!MessageSummary.isLong(String(repeating: "palabra ", count: 80)))
    }

    @Test func theModelGetsWhatFitsItsContextAndNotesWhatWasCut() {
        let short = "Uno.\n\nDos.\n\nTres."
        #expect(MessageSummary.input(short) == short)
        let long = String(repeating: "a", count: MessageSummary.maxInputCharacters + 500)
        let input = MessageSummary.input(long)
        #expect(input.hasPrefix(String(repeating: "a", count: MessageSummary.maxInputCharacters)))
        #expect(input.count < long.count)
        #expect(input.hasSuffix("[…]"))
    }
}

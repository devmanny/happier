import Testing
@testable import HappierKit

/// Moving the cursor a line up or down from the text around it (a keyboard sees no layout).
struct KeyboardCursorTests {
    @Test func upGoesToTheSameColumnOfTheLineAbove() {
        // "hola mundo\nque| tal" → "hol|a mundo"
        #expect(KeyboardCursor.lineOffset(.up, before: "hola mundo\nque", after: " tal", lineLength: 40) == -11)
    }

    @Test func upStopsAtTheEndOfAShorterLineAbove() {
        // "hi\nhello |world" → "hi|"
        #expect(KeyboardCursor.lineOffset(.up, before: "hi\nhello ", after: "world", lineLength: 40) == -7)
    }

    @Test func upOnTheFirstLineGoesToTheStart() {
        #expect(KeyboardCursor.lineOffset(.up, before: "hola", after: " mundo", lineLength: 40) == -4)
    }

    @Test func downGoesToTheSameColumnOfTheLineBelow() {
        // "hol|a mundo\nque tal" → "que| tal"
        #expect(KeyboardCursor.lineOffset(.down, before: "hol", after: "a mundo\nque tal", lineLength: 40) == 11)
    }

    @Test func downStopsAtTheEndOfAShorterLineBelow() {
        // "hello wo|rld\nhi" → "hi|"
        #expect(KeyboardCursor.lineOffset(.down, before: "hello wo", after: "rld\nhi", lineLength: 40) == 6)
    }

    @Test func downOnTheLastLineGoesToTheEnd() {
        #expect(KeyboardCursor.lineOffset(.down, before: "ho", after: "la", lineLength: 40) == 2)
    }

    @Test func aLongParagraphMovesByWrappedLines() {
        let paragraph = String(repeating: "a", count: 25)
        // Column 22 of a paragraph wrapped every 10: up one wrapped line, then down one.
        #expect(KeyboardCursor.lineOffset(.up, before: String(paragraph.prefix(22)), after: String(paragraph.dropFirst(22)), lineLength: 10) == -10)
        #expect(KeyboardCursor.lineOffset(.down, before: String(paragraph.prefix(12)), after: String(paragraph.dropFirst(12)), lineLength: 10) == 10)
        // From the second-to-last wrapped line, down stops at the paragraph's end.
        #expect(KeyboardCursor.lineOffset(.down, before: String(paragraph.prefix(18)), after: String(paragraph.dropFirst(18)), lineLength: 10) == 7)
    }

    @Test func upFromAParagraphLandsOnTheLastWrappedLineAbove() {
        // The line above is 25 long, wrapped every 10: its last wrapped line starts at 20.
        let above = String(repeating: "a", count: 25)
        #expect(KeyboardCursor.lineOffset(.up, before: above + "\nbc", after: "", lineLength: 10) == -6)
    }
}

import Testing
@testable import HappierKit

/// Mirrors `apps/ui/sources/components/markdown/parseMarkdownBlock.ts` (options + fenced code).
@Suite struct MarkdownSegmentsTests {
    @Test func extractsWrappedOptionsBlock() {
        let text = """
        Done. What next?

        <options>
            <option>Commit and push</option>
            <option>Run the tests</option>
        </options>
        """
        #expect(MarkdownSegments.parse(text) == [.prose("Done. What next?"), .options(["Commit and push", "Run the tests"])])
    }

    @Test func acceptsBareOptionLinesAndStopsAtProse() {
        let text = "<option>Yes</option>\n<option>No</option>\nThanks"
        #expect(MarkdownSegments.parse(text) == [.options(["Yes", "No"]), .prose("Thanks")])
    }

    @Test func optionsInsideCodeFencesStayCode() {
        let text = "```xml\n<options>\n<option>A</option>\n</options>\n```"
        #expect(MarkdownSegments.parse(text) == [.code("<options>\n<option>A</option>\n</options>")])
    }

    @Test func emptyOptionsBlockIsDropped() {
        #expect(MarkdownSegments.parse("Hi\n<options>\n</options>") == [.prose("Hi")])
    }
}

import XCTest
@testable import Happier

/// The Pencil's link text is rebuilt from pieces; it must read exactly as the message and keep each
/// link on its own words.
final class PencilLinksTests: XCTestCase {
    func testPiecesKeepTheTextAndPutEachLinkOnItsWords() {
        let text = MarkdownText.attributed("😀 Docs: [first](https://first.example) and **bold**\nHome: [Happier](https://happier.dev)")
        let pieces = PencilLinks.pieces(text)

        XCTAssertEqual(String(pieces.map { String($0.text.characters) }.joined()), String(text.characters))
        XCTAssertEqual(pieces.compactMap(\.link), [URL(string: "https://first.example")!, URL(string: "https://happier.dev")!])
        XCTAssertEqual(pieces.filter { $0.link != nil }.map { String($0.text.characters) }, ["first", "Happier"])
        // Styling inside a piece stays (the bold run is still bold).
        XCTAssertTrue(pieces.contains { $0.text.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized } })
    }
}

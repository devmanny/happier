import Testing
@testable import HappierKit

@Suite struct ChatScrollTests {
    // Numbers from a device measurement: 679pt between a 126pt nav-bar inset and the composer.
    private func g(offset: Double, content: Double, container: Double = 679, top: Double = 126) -> ChatScroll.Geometry {
        .init(offsetY: offset, containerHeight: container, contentHeight: content, topInset: top)
    }

    @Test func theEndSitsJustAboveTheComposer() {
        #expect(g(offset: 0, content: 2026).endOffset == 1221)
        // A taller composer leaves less room, so the end moves down.
        #expect(g(offset: 0, content: 2026, container: 600).endOffset == 1300)
    }

    @Test func aPinnedChatKeepsReturningToTheEnd() {
        // Rows measured taller, or the composer grew: the viewport is now short of the end.
        #expect(ChatScroll.shouldFollow(pinned: true, geometry: g(offset: 1221, content: 2090)))
        #expect(ChatScroll.shouldFollow(pinned: true, geometry: g(offset: 1221, content: 2026, container: 600)))
        // A row collapsed and left a gap below the last message.
        #expect(ChatScroll.shouldFollow(pinned: true, geometry: g(offset: 1221, content: 1800)))
        #expect(!ChatScroll.shouldFollow(pinned: true, geometry: g(offset: 1221, content: 2026)))
    }

    @Test func aShortChatRestsAtTheTopAndNeedsNoFollowing() {
        // Measured: 517pt of messages bottom-anchored with a 288pt top inset rest at y = -288.
        let resting = g(offset: -288, content: 517, top: 288)
        #expect(resting.endOffset == -288)
        #expect(resting.fitsOnScreen && !g(offset: 1221, content: 2026).fitsOnScreen)
        #expect(!ChatScroll.shouldFollow(pinned: true, geometry: resting))
        // Pulled past the top while settling (measured y = -450): the scroll view bounces back by
        // itself; following it would fight the bounce.
        #expect(!ChatScroll.shouldFollow(pinned: true, geometry: g(offset: -450, content: 517, top: 288)))
    }

    @Test func anUnpinnedReaderIsLeftAlone() {
        #expect(!ChatScroll.shouldFollow(pinned: false, geometry: g(offset: 100, content: 2026)))
    }

    @Test func draggingBackToTheEndPinsAgain() {
        #expect(ChatScroll.isPinned(afterUserScrollTo: g(offset: 1200, content: 2026)))
        #expect(!ChatScroll.isPinned(afterUserScrollTo: g(offset: 600, content: 2026)))
    }

    @Test func theJumpToLatestButtonAppearsOnceYouHaveScrolledWellAboveTheEnd() {
        #expect(!ChatScroll.showsJumpToLatest(g(offset: 1221, content: 2026)))   // at the end
        #expect(!ChatScroll.showsJumpToLatest(g(offset: 1100, content: 2026)))   // a nudge up
        #expect(ChatScroll.showsJumpToLatest(g(offset: 800, content: 2026)))     // reading history
        #expect(!ChatScroll.showsJumpToLatest(g(offset: -288, content: 517, top: 288)))  // fits on screen
    }
}

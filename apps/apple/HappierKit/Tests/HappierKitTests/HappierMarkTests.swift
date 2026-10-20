import Testing
@testable import HappierKit

/// The RN app's default loading indicator: `wave` on the Happier mark (`dotSpinnerStyles.ts`),
/// at Normal speed with the Short pause.
@Suite struct HappierMarkTests {
    private func dot(_ id: String) -> HappierMark.Dot { HappierMark.dots.first { $0.id == id }! }

    @Test func theMarkIsAnHWithAFootOnA3x3Grid() {
        #expect(HappierMark.dots.map(\.id) == ["TL", "ML", "BL", "MC", "TR", "MR", "BR", "BC"])
        #expect(!HappierMark.dots.contains { $0.col == 1 && $0.row == 0 })
    }

    @Test func theLightCrossesFromTheBottomLeftFootToTheTopRightCorner() {
        // One loop: 4 diagonal steps × 110 ms + a 364 ms pulse, then a 200 ms rest.
        #expect(HappierMark.cycleMs == 1004)
        #expect(HappierMark.opacity(dot("BL"), atMs: 0) == HappierMark.restOpacity)
        #expect(HappierMark.opacity(dot("BL"), atMs: 65) == 1)          // first dot at full light
        #expect(HappierMark.opacity(dot("TR"), atMs: 65) == HappierMark.restOpacity)
        #expect(HappierMark.opacity(dot("TR"), atMs: 4 * 110 + 65) == 1) // last dot lights 440 ms later
        // During the rest every dot is dim, and the loop repeats.
        #expect(HappierMark.dots.allSatisfy { HappierMark.opacity($0, atMs: 900) == HappierMark.restOpacity })
        #expect(HappierMark.opacity(dot("BL"), atMs: 1004 + 65) == 1)
    }
}

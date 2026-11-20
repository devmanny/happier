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

    /// Core Animation plays the mark from keyframes, off the main thread: they trace the same
    /// light at every moment of the loop.
    @Test func keyframesTraceTheSameLight() {
        for dot in HappierMark.dots {
            let frames = HappierMark.keyframes(for: dot)
            #expect(frames.first?.time == 0)
            #expect(frames.last?.time == 1)
            #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.time <= $1.time })
            for ms in stride(from: 0.0, to: HappierMark.cycleMs, by: 7) {
                let t = ms / HappierMark.cycleMs
                let after = frames.firstIndex { $0.time >= t } ?? frames.count - 1
                let b = frames[after], a = frames[max(after - 1, 0)]
                let played = b.time == a.time ? b.opacity : a.opacity + (b.opacity - a.opacity) * (t - a.time) / (b.time - a.time)
                #expect(abs(played - HappierMark.opacity(dot, atMs: ms)) < 0.0001, "\(dot.id) at \(ms) ms")
            }
        }
    }
}

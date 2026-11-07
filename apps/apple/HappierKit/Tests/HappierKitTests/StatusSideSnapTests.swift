import Testing
@testable import HappierKit

/// Dropping the dragged status pill: it goes to the side its projected resting point is on, as a
/// flicked Picture in Picture window does.
@Suite struct StatusSideSnapTests {
    @Test func releasedSlowlyItGoesToTheNearestSide() {
        #expect(StatusSideSnap.side(center: 100, velocity: 0, width: 400) == .left)
        #expect(StatusSideSnap.side(center: 260, velocity: 30, width: 400) == .right)
    }

    @Test func flickedHardItGoesTheWayItWasThrownEvenFromNearTheOtherSide() {
        #expect(StatusSideSnap.side(center: 120, velocity: 900, width: 400) == .right)
        #expect(StatusSideSnap.side(center: 300, velocity: -900, width: 400) == .left)
        // A light flick doesn't carry it across.
        #expect(StatusSideSnap.side(center: 120, velocity: 150, width: 400) == .left)
    }

    @Test func projectsLikeScrollDeceleration() {
        #expect(abs(StatusSideSnap.projectedDistance(velocity: 1_000) - 499) < 1)
    }
}

import Testing
@testable import HappierKit

/// A session's bar keeps its title in view: at most three buttons beside it, two when a back
/// button already sits there. Everything else is in the ⓘ menu, which is always there.
struct SessionToolbarLayoutTests {
    @Test func atMostThreeButtonsAndTwoBesideABackButton() {
        let alone = SessionToolbarLayout.slots(hasBackButton: false)
        let withBack = SessionToolbarLayout.slots(hasBackButton: true)
        #expect(alone.count <= 3)
        #expect(withBack.count <= 2)
        #expect(alone.contains(.details) && withBack.contains(.details))
    }

    @Test func whatLeavesTheBarIsInTheMenu() {
        for hasBackButton in [false, true] {
            let bar = SessionToolbarLayout.slots(hasBackButton: hasBackButton)
            #expect(SessionToolbarLayout.readAloudInMenu(hasBackButton: hasBackButton) == !bar.contains(.readAloud))
        }
    }
}

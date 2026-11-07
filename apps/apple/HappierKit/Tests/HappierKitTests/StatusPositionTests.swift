import Foundation
import Testing
@testable import HappierKit

/// Where the composer's status line sits, kept in the account settings so every device agrees.
@Suite struct StatusPositionTests {
    @Test func theStatusLineIsOnTheLeftUntilTheUserMovesIt() {
        var settings = AccountSettings(values: ["other": "kept"])
        #expect(settings.statusPosition == .left)
        settings = settings.merging(settings.delta(statusPosition: .right))
        #expect(settings.statusPosition == .right)
        #expect(settings.values["other"] == "kept")
        #expect(AccountSettings(values: [AccountSettings.statusPositionKey: "center"]).statusPosition == .left)
    }
}

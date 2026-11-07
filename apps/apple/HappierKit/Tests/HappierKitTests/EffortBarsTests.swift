import Testing
@testable import HappierKit

/// The model pill's effort mark: one bar per level the model's catalog offers, filled up to the
/// current one; Ultracode shows them all filled.
@Suite struct EffortBarsTests {
    static let claude = ["low", "medium", "high", "xhigh", "max"]
    static let codex = ["minimal", "low", "medium", "high", "xhigh", "ultra"]

    @Test func claudeHasFiveBarsFilledToTheLevel() {
        #expect(EffortBars(level: "high", levels: Self.claude) == EffortBars(count: 5, filled: 3))
        #expect(EffortBars(level: "max", levels: Self.claude) == EffortBars(count: 5, filled: 5))
        #expect(EffortBars(level: "low", levels: Self.claude, ultracode: true) == EffortBars(count: 5, filled: 5))
    }

    @Test func codexHasSixBarsIncludingUltra() {
        #expect(EffortBars(level: "medium", levels: Self.codex) == EffortBars(count: 6, filled: 3))
        #expect(EffortBars(level: "ultra", levels: Self.codex) == EffortBars(count: 6, filled: 6))
    }

    @Test func aLevelTheCatalogDoesNotListFillsNothingButKeepsTheCount() {
        #expect(EffortBars(level: "turbo", levels: Self.claude) == EffortBars(count: 5, filled: 0))
        #expect(EffortBars(level: "high", levels: []) == nil)
    }
}

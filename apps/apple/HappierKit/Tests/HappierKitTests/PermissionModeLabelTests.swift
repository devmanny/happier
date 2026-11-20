import Testing
@testable import HappierKit

/// A permission mode's name and symbol, decided in one place for every provider.
@Suite struct PermissionModeLabelTests {
    @Test func defaultIsAskWhereItAsksAndCLISettingsElsewhere() {
        for agent in ["claude", "gemini"] {
            #expect(PermissionMode.default.label(agentId: agent) == "Ask")
            #expect(PermissionMode.default.symbolName(agentId: agent) == "questionmark.circle")
        }
        #expect(PermissionMode.default.label(agentId: "codex") == "CLI Settings")
        #expect(PermissionMode.default.symbolName(agentId: "codex") == "circle")
        #expect(PermissionMode.default.symbolName(agentId: nil) == "circle")
        // The stored value doesn't change.
        #expect(PermissionMode.default.rawValue == "default")
    }

    @Test func theOtherModesKeepOneSymbolEach() {
        #expect(PermissionMode.readOnly.symbolName(agentId: "codex") == "eye.circle")
        #expect(PermissionMode.safeYolo.symbolName(agentId: "claude") == "bolt.circle")
        #expect(PermissionMode.yolo.symbolName(agentId: "gemini") == "checkmark.circle")
    }
}

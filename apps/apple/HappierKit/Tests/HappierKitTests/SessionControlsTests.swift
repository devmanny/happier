import Testing
@testable import HappierKit

/// Composer controls (`packages/agents/src/sessionControls/**`, `apps/ui/sources/sync/domains/{models,permissions,sessionControl}`).
@Suite struct SessionControlsTests {
    @Test func claudeFallsBackToStaticCatalogWithEffort() {
        let controls = SessionControls(metadata: ["flavor": "claude"], agentId: "claude")
        #expect(controls.selectedModelId == "default")
        #expect(controls.models.first?.id == "claude-fable-5-1")
        let opus = controls.models.first { $0.id == "claude-opus-5-5" }
        #expect(opus?.effortLevels == ["low", "medium", "high", "xhigh", "max"])
        #expect(opus?.defaultEffort == "medium")
        #expect(opus?.supportsUltracode == true)
        #expect(controls.models.first { $0.id == "claude-haiku-4-5" }?.effortLevels == [])
    }

    @Test func dynamicModelsRequireMatchingProviderAndNewestAlias() {
        let models: JSONValue = ["v": 1, "provider": "codex", "updatedAt": 10, "currentModelId": "gpt-a",
                                 "availableModels": [["id": "gpt-a", "name": "GPT A"], ["id": "gpt-b", "name": "GPT B"]]]
        let older: JSONValue = ["v": 1, "provider": "codex", "updatedAt": 5, "currentModelId": "old", "availableModels": [["id": "old", "name": "Old"]]]
        let controls = SessionControls(metadata: ["acpSessionModelsV1": models, "sessionModelsV1": older], agentId: "codex")
        #expect(controls.models.map(\.id) == ["gpt-a", "gpt-b"])
        let mismatched = SessionControls(metadata: ["sessionModelsV1": models], agentId: "claude")
        #expect(!mismatched.models.contains { $0.id == "gpt-a" })
    }

    @Test func readsSelectionAppliedModelEffortAndPermission() {
        let metadata: JSONValue = [
            "modelOverrideV1": ["v": 1, "updatedAt": 3, "modelId": "claude-opus-5-5"],
            "sessionAppliedModelV1": ["v": 1, "provider": "claude", "updatedAt": 2, "modelId": "claude-sonnet-5-5"],
            "sessionConfigOptionOverridesV1": ["v": 1, "updatedAt": 4, "overrides": ["reasoning_effort": ["updatedAt": 4, "value": "high"]]],
            "permissionMode": "bypassPermissions",
        ]
        let controls = SessionControls(metadata: metadata, agentId: "claude")
        #expect(controls.selectedModelId == "claude-opus-5-5")
        #expect(controls.appliedModelId == "claude-sonnet-5-5")
        #expect(controls.effort == "high")
        #expect(controls.permissionMode == .yolo)
        #expect(SessionControls(metadata: ["permissionMode": "acceptEdits"], agentId: "claude").permissionMode == .safeYolo)
        #expect(SessionControls(metadata: ["modelOverrideV1": ["v": 1, "updatedAt": 3, "modelId": nil]], agentId: "claude").selectedModelId == "default")
    }

    @Test func modelWriteForcesNewerTimestamp() {
        let metadata: JSONValue = ["path": "/a", "modelOverrideV1": ["v": 1, "updatedAt": 100, "modelId": "x"]]
        let edited = MetadataEdit.setModel("claude-opus-5-5", in: metadata, now: 50)
        #expect(edited["modelOverrideV1"] == ["v": 1, "updatedAt": 101, "modelId": "claude-opus-5-5"])
        #expect(edited["path"] == "/a")
    }

    @Test func permissionWriteIgnoresOlderTimestamps() {
        let metadata: JSONValue = ["permissionMode": "default", "permissionModeUpdatedAt": 100]
        #expect(MetadataEdit.setPermissionMode(.yolo, in: metadata, now: 200)["permissionMode"] == "yolo")
        #expect(MetadataEdit.setPermissionMode(.yolo, in: metadata, now: 200)["permissionModeUpdatedAt"] == 200)
        #expect(MetadataEdit.setPermissionMode(.yolo, in: metadata, now: 50) == metadata)
    }

    @Test func configOptionWriteMergesIntoBothAliases() {
        let metadata: JSONValue = ["sessionConfigOptionOverridesV1": ["v": 1, "updatedAt": 5, "overrides": ["ultracode": ["updatedAt": 5, "value": "true"]]]]
        let edited = MetadataEdit.setConfigOption("reasoning_effort", value: "max", in: metadata, now: 9)
        let expected: JSONValue = ["v": 1, "updatedAt": 9, "overrides": [
            "ultracode": ["updatedAt": 5, "value": "true"], "reasoning_effort": ["updatedAt": 9, "value": "max"]]]
        #expect(edited["sessionConfigOptionOverridesV1"] == expected)
        #expect(edited["acpConfigOptionOverridesV1"] == expected)
    }

    @Test func outgoingMetaCarriesModelAndClaudeEffort() {
        let metadata: JSONValue = [
            "permissionMode": "safe-yolo",
            "modelOverrideV1": ["v": 1, "updatedAt": 3, "modelId": "claude-opus-5-5"],
            "sessionConfigOptionOverridesV1": ["v": 1, "updatedAt": 4, "overrides": [
                "reasoning_effort": ["updatedAt": 4, "value": "High"], "ultracode": ["updatedAt": 4, "value": "false"]]],
        ]
        let meta = SessionControls(metadata: metadata, agentId: "claude").messageMeta
        #expect(meta == ["permissionMode": "safe-yolo", "model": "claude-opus-5-5", "reasoningEffort": "high", "ultracode": false])
        #expect(SessionControls(metadata: [:], agentId: "codex").messageMeta == ["permissionMode": "default"])
    }

    @Test func slashCommandsPreferDetailsAndIncludeDefaults() {
        let controls = SessionControls(metadata: ["slashCommandDetails": [["command": "review", "description": "Review code"]], "slashCommands": ["ignored"]], agentId: "claude")
        #expect(controls.slashCommands.map(\.command).prefix(3) == ["review", "compact", "clear"])
        #expect(!controls.slashCommands.contains { $0.command == "ignored" })
    }
}

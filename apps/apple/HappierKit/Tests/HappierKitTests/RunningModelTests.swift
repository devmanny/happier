import Foundation
import Testing
@testable import HappierKit

/// The model a session runs on, as the list shows it (one word) and filters by it.
@Suite struct RunningModelTests {
    private func session(_ id: String, flavor: String = "claude", selected: String? = nil, applied: String? = nil,
                         current: String? = nil, appliedProvider: String? = nil, title: String? = nil) throws -> Session {
        var metadata: [String: JSONValue] = ["path": "/Users/manny/Projects/app", "name": .string(title ?? id), "flavor": .string(flavor)]
        if let selected { metadata["modelOverrideV1"] = ["v": 1, "updatedAt": 3, "modelId": .string(selected)] }
        if let applied {
            metadata["sessionAppliedModelV1"] = ["v": 1, "provider": .string(appliedProvider ?? flavor), "updatedAt": 2, "modelId": .string(applied)]
        }
        if let current {
            metadata["sessionModelsV1"] = ["v": 1, "provider": .string(flavor), "updatedAt": 5, "currentModelId": .string(current),
                                           "availableModels": [["id": .string(current), "name": .string("Named \(current)")]]]
        }
        let row: [String: JSONValue] = [
            "id": .string(id), "encryptionMode": "plain", "metadataVersion": 1, "active": true, "updatedAt": 10,
            "metadata": .string(String(decoding: try JSONValue.object(metadata).encoded(), as: UTF8.self)),
        ]
        return try Session(row: .object(row), keys: nil)
    }

    @Test func aModelIsNamedInOneWord() {
        #expect(RunningModel.word(for: "claude-fable-5-2") == "Fable")
        #expect(RunningModel.word(for: "claude-opus-5-5") == "Opus")
        #expect(RunningModel.word(for: "opus[1m]") == "Opus")
        #expect(RunningModel.word(for: "claude-haiku-4-5-20251001") == "Haiku")
        #expect(RunningModel.word(for: "gpt-6.1-sol") == "Sol")
        #expect(RunningModel.word(for: "gpt-6-astra") == "Astra")
        #expect(RunningModel.word(for: "kimi-code/k3.1-pro") == "K3.1")
        #expect(RunningModel.word(for: "gemini-3-pro-preview") == "Pro")
        // No word of its own: the vendor and its version.
        #expect(RunningModel.word(for: "gpt-5") == "GPT-5")
        // "Use CLI settings" names no model.
        #expect(RunningModel.word(for: "default") == nil)
        #expect(RunningModel.word(for: "  ") == nil)
    }

    @Test func aModelIsCalledAsTheCatalogCallsIt() {
        #expect(RunningModel.name(for: "claude-opus-5-5") == "Opus 5.5")
        #expect(RunningModel.name(for: "claude-fable-5-2") == "Fable 5.2")
        #expect(RunningModel.name(for: "gpt-6.1-sol") == "gpt-6.1-sol")
        #expect(RunningModel.name(for: "opus") == "Opus")
    }

    @Test func aSessionRunsOnTheChosenModelElseWhatTheRuntimeReports() throws {
        // The choice wins over what the runtime applied before it.
        let chosen = try session("chosen", selected: "claude-opus-4-7", applied: "claude-sonnet-5-5")
        #expect(chosen.runningModel == RunningModel(id: "claude-opus-4-7", word: "Opus"))
        // "Use CLI settings": what the runtime says it is on.
        let cli = try session("cli", applied: "default", current: "claude-fable-5-2")
        #expect(cli.runningModel == RunningModel(id: "claude-fable-5-2", word: "Fable"))
        // An alias is known by the model it runs as…
        let alias = try session("alias", selected: "opus[1m]", applied: "opus[1m]", current: "claude-opus-5-5")
        #expect(alias.runningModel == RunningModel(id: "claude-opus-5-5", word: "Opus"))
        // …unless the runtime is still on another family (the switch hasn't landed).
        let switching = try session("switching", selected: "sonnet", current: "claude-opus-5-5")
        #expect(switching.runningModel == RunningModel(id: "sonnet", word: "Sonnet"))
        // What another agent's runtime left behind doesn't count.
        let stale = try session("stale", flavor: "codex", applied: "claude-opus-5-5", appliedProvider: "claude")
        #expect(stale.runningModel == nil)
        #expect(try session("unknown").runningModel == nil)
        #expect(try session("codex", flavor: "codex", current: "gpt-6.1-sol").runningModel?.word == "Sol")
    }

    @Test func theSearchFindsSessionsByTheirModel() throws {
        let opus = try session("a", selected: "claude-opus-5-5", title: "Invoices")
        #expect(opus.matches("opus"))
        #expect(opus.matches("Opus 5.5"))
        #expect(opus.matches("invoi"))
        #expect(!opus.matches("fable"))
        #expect(try session("b", flavor: "codex", current: "gpt-6.1-sol", title: "Invoices").matches("gpt-6.1"))
    }

    // MARK: The filter

    private func shown(_ filter: SessionListFilter, _ sessions: [Session]) -> [String] {
        let context = SessionListFilter.Context(tasks: [])
        return sessions.filter { filter.includes($0, context: context) }.map(\.id)
    }

    private func all() throws -> [Session] {
        [
            try session("opus55", selected: "claude-opus-5-5"), try session("opus47", selected: "claude-opus-4-7"),
            try session("fable", current: "claude-fable-5-2"), try session("sol", flavor: "codex", current: "gpt-6.1-sol"),
            try session("unknown", flavor: "codex"),
        ]
    }

    @Test func theListFiltersByProviderFamilyAndExactModel() throws {
        let sessions = try all()
        var filter = SessionListFilter.default
        filter.provider = "codex"
        #expect(shown(filter, sessions) == ["sol", "unknown"])
        filter = .default
        filter.modelFamily = "Opus"
        #expect(shown(filter, sessions) == ["opus55", "opus47"])
        filter.modelId = "claude-opus-5-5"
        #expect(shown(filter, sessions) == ["opus55"])
        // Provider and model together.
        filter = .default
        filter.provider = "claude"
        filter.modelFamily = "Sol"
        #expect(shown(filter, sessions).isEmpty)
        #expect(!filter.isDefault)
    }

    @Test func theModelFilterIsStoredAndOlderStoredFiltersStillRead() throws {
        var filter = SessionListFilter.default
        filter.provider = "claude"
        filter.modelFamily = "Opus"
        filter.modelId = "claude-opus-5-5"
        #expect(SessionListFilter(stored: filter.stored) == filter)
        // Stored before the model filter existed.
        let older = #"{"agent":{"all":{}},"attentionOnly":false,"kinds":["normal","sub"],"states":["active","inactive"]}"#
        #expect(SessionListFilter(stored: older) == .default)
    }

    @Test func theFilterIsSummedUpWithItsProviderAndModel() {
        var filter = SessionListFilter.default
        filter.provider = "codex"
        #expect(filter.summary { _ in nil } == "Codex")
        filter.modelFamily = "Opus"
        #expect(filter.summary { _ in nil } == "Codex · Opus")
        filter.modelId = "claude-opus-5-5"
        #expect(filter.summary { _ in nil } == "Codex · Opus 5.5")
    }

    @Test func theFilterOffersTheProvidersAndModelsTheSessionsRunOn() throws {
        let options = SessionListFilter.ModelOptions(sessions: try all())
        #expect(options.providers == ["claude", "codex"])
        #expect(options.families.map(\.word) == ["Fable", "Opus", "Sol"])
        let opus = try #require(options.families.first { $0.word == "Opus" })
        #expect(opus.provider == "claude")
        // Newest first, named as the catalog (or the session's own list) names them.
        #expect(opus.models.map(\.name) == ["Opus 5.5", "Opus 4.7"])
        #expect(options.families.first { $0.word == "Sol" }?.models.map(\.name) == ["Named gpt-6.1-sol"])
        #expect(options.families(for: "codex").map(\.word) == ["Sol"])
        #expect(options.families(for: nil).count == 3)
    }
}

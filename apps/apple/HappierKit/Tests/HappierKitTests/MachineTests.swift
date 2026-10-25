import Foundation
import Testing
@testable import HappierKit

/// Machines for "New Session" (`syncMachines.ts`, `machineEncryption.ts`, `machineStoredContent.ts`).
@Suite struct MachineTests {
    let keys = try! AccountKeys(masterSecret: Data(0..<32))

    @Test func decryptsE2EEMachineMetadata() throws {
        let dataKey = Data(repeating: 4, count: 32)
        let envelope = try HappierCrypto.sealDataKeyEnvelope(dataKey, recipientPublicKey: keys.content.publicKey)
        let metadata: JSONValue = ["host": "mbp.local", "displayName": "Manny's Mac", "platform": "darwin", "homeDir": "/Users/manny", "happyCliVersion": "0.2.12"]
        let machine = try Machine(row: [
            "id": "m1", "active": true, "activeAt": 1000,
            "dataEncryptionKey": .string(envelope.base64EncodedString()),
            "metadata": .string(try ContentCipher.aesGCM(key: dataKey).encryptBase64(metadata)),
        ], keys: keys)
        #expect(machine.name == "Manny's Mac" && machine.homeDir == "/Users/manny" && machine.active)
        #expect(machine.cliVersion == "0.2.12")
    }

    @Test func readsPlainMachinesAndFallsBackToHost() throws {
        let marker = Data(#"{"t":"plain","v":null}"#.utf8).base64EncodedString()
        let doc = Data(#"{"t":"plain","v":{"host":"devbox","homeDir":"/home/m"}}"#.utf8).base64EncodedString()
        let machine = try Machine(row: ["id": "m2", "active": false, "dataEncryptionKey": JSONValue.string(marker), "metadata": JSONValue.string(doc)] as JSONValue, keys: nil)
        #expect(machine.name == "devbox" && machine.homeDir == "/home/m" && !machine.active)
    }

    @Test func recentDirectoriesComeFromThatMachinesSessions() throws {
        func session(_ id: String, _ machine: String, _ path: String, _ at: Double) throws -> Session {
            try Session(row: ["id": .string(id), "seq": 1, "createdAt": 1, "updatedAt": .number(at), "active": false,
                              "encryptionMode": "plain", "metadata": .string(#"{"path":"\#(path)","machineId":"\#(machine)"}"#), "metadataVersion": 1], keys: nil)
        }
        let sessions = [try session("a", "m1", "/p/one", 10), try session("b", "m1", "/p/two", 30), try session("c", "m2", "/p/x", 50), try session("d", "m1", "/p/one", 40)]
        #expect(Machine.recentDirectories(machineId: "m1", sessions: sessions) == ["/p/one", "/p/two"])
    }
}

/// The daemon validates spawn timestamps with `z.number().int()` (`sessionRunnerRespawnDescriptor.ts`);
/// a fractional value made it fail with "Could not persist accepted spawn custody".
@Suite struct SpawnRequestTests {
    @Test func spawnParamsUseWholeMilliseconds() {
        let params = SpawnRequest.params(directory: "/p", agentId: "claude", permissionMode: .yolo,
                                         nonce: "n", approveNewDirectory: false, now: 1_792_390_564_181.535)
        #expect(params["permissionModeUpdatedAt"] == 1_792_390_564_181)
        #expect(params["permissionMode"] == "yolo" && params["spawnNonce"] == "n")
        #expect(params["backendTarget"] == ["kind": "builtInAgent", "agentId": "claude"])
    }

    @Test func spawnParamsSeedModelAndEffort() {
        let params = SpawnRequest.params(directory: "/p", agentId: "claude", permissionMode: .yolo, modelId: "claude-opus-5-5",
                                         effort: "high", nonce: "n", approveNewDirectory: false, now: 1_000)
        #expect(params["modelId"] == "claude-opus-5-5" && params["modelUpdatedAt"] == 1_000)
        #expect(params["sessionConfigOptionOverrides"] == ["v": 1, "updatedAt": 1_000,
                                                           "overrides": ["reasoning_effort": ["updatedAt": 1_000, "value": "high"]]])
    }

    @Test func spawnParamsLeaveCLISettingsAlone() {
        let params = SpawnRequest.params(directory: "/p", agentId: "codex", permissionMode: .yolo, modelId: "default",
                                         effort: nil, nonce: "n", approveNewDirectory: false, now: 1_000)
        #expect(params["modelId"] == nil && params["modelUpdatedAt"] == nil)
        #expect(params["sessionConfigOptionOverrides"] == nil)
    }

    /// Switching a live session's agent carries the picked model and effort the same way a new
    /// session does (`SessionAgentTransitionSelectionV1`: `modelId` + `sessionConfigOptionOverrides`).
    @Test func agentTransitionParamsCarryModelAndEffort() {
        let selection = HappierStore.AgentSelection(agentId: "codex", modelId: "gpt-6", effort: "high")
        let params = AgentTransitionRequest.params(sessionId: "s1", currentAgentId: "claude", selection: selection,
                                                   text: "hi", localId: "l1", meta: ["source": "ui"], now: 1_000)
        #expect(params["sessionId"] == "s1" && params["expectedCurrentAgentId"] == "claude")
        #expect(params["selection"] == ["v": 1, "agentId": "codex", "modelId": "gpt-6",
                                        "sessionConfigOptionOverrides": ["v": 1, "updatedAt": 1_000,
                                                                         "overrides": ["reasoning_effort": ["updatedAt": 1_000, "value": "high"]]]])
        #expect(params["input"] == ["text": "hi", "localId": "l1", "meta": ["source": "ui"]])
    }

    @Test func agentTransitionParamsLeaveCLISettingsAlone() {
        let selection = HappierStore.AgentSelection(agentId: "codex", modelId: "default", effort: nil)
        let params = AgentTransitionRequest.params(sessionId: "s1", currentAgentId: "claude", selection: selection,
                                                   text: "hi", localId: "l1", meta: [:], now: 1_000)
        #expect(params["selection"] == ["v": 1, "agentId": "codex"])
    }

    @Test func serverClockIsWholeMilliseconds() {
        let now = ServerClock.nowMs()
        #expect(now == now.rounded(.down))
    }
}

/// The new-session agent picker lists what the machine has installed (`capabilities.detect`,
/// checklist `new-session`), not a fixed set: Gemini showed up for someone who never had it.
@Suite struct InstalledAgentsTests {
    @Test func readsTheAgentsTheMachineHas() {
        let response: JSONValue = ["protocolVersion": 1, "results": [
            "cli.claude": ["ok": true, "checkedAt": 1, "data": ["available": true, "version": "2.1"]],
            "cli.kimi": ["ok": true, "checkedAt": 1, "data": ["available": true]],
            "cli.gemini": ["ok": true, "checkedAt": 1, "data": ["available": false]],
            "cli.codex": ["ok": false, "checkedAt": 1, "error": ["message": "boom"]],
            "tool.tmux": ["ok": true, "checkedAt": 1, "data": ["available": true]],
        ]]
        #expect(Agent.installed(fromDetect: response) == ["claude", "kimi"])
        #expect(Agent.installed(fromDetect: ["error": "nope"]) == nil)
    }
}

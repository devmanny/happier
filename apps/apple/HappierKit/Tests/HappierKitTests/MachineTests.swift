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

/// The Machines screen (`machineUtils.ts`, `syncMachines.ts`, `machine/[id]/index.tsx`,
/// `machineUpdateHandler.ts`, `capabilitiesProtocol.ts`).
@Suite struct MachineManagementTests {
    let keys = try! AccountKeys(masterSecret: Data(0..<32))
    let dataKey = Data(repeating: 4, count: 32)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var nowMs: Double { now.timeIntervalSince1970 * 1000 }

    private func row(_ extra: [String: JSONValue] = [:], daemon: JSONValue? = nil) throws -> JSONValue {
        let envelope = try HappierCrypto.sealDataKeyEnvelope(dataKey, recipientPublicKey: keys.content.publicKey)
        let cipher = ContentCipher.aesGCM(key: dataKey)
        var row: [String: JSONValue] = [
            "id": "m1", "active": true, "activeAt": .number(nowMs - 5_000), "createdAt": 1000,
            "dataEncryptionKey": .string(envelope.base64EncodedString()),
            "metadata": .string(try cipher.encryptBase64(["host": "mbp.local", "platform": "darwin", "homeDir": "/Users/m"])),
            "metadataVersion": 4, "daemonStateVersion": 2,
            "daemonState": try daemon.map { .string(try cipher.encryptBase64($0)) } ?? .null,
        ]
        row.merge(extra) { $1 }
        return .object(row)
    }

    @Test func onlineFollowsTheLastHeartbeatWithinAMinute() throws {
        #expect(try Machine(row: row(), keys: keys).isOnline(at: now))
        #expect(try !Machine(row: row(["activeAt": .number(nowMs - 61_000)]), keys: keys).isOnline(at: now))
        // Without a heartbeat time, the server's flag decides.
        #expect(try Machine(row: row(["activeAt": .null]), keys: keys).isOnline(at: now))
        #expect(try !Machine(row: row(["activeAt": .null, "active": false]), keys: keys).isOnline(at: now))
        #expect(try !Machine(row: row(["revokedAt": .number(nowMs)]), keys: keys).isOnline(at: now))
        #expect(try !Machine(row: row(["replacedByMachineId": "m2"]), keys: keys).isOnline(at: now))
    }

    @Test func decryptsTheDaemonState() throws {
        let machine = try Machine(row: row(daemon: ["status": "running", "pid": 4242, "httpPort": 51000, "startedAt": .number(nowMs - 60_000),
                                                    "startedWithCliVersion": "0.2.17"]), keys: keys)
        #expect(machine.daemon?.pid == 4242 && machine.daemon?.httpPort == 51000 && machine.daemon?.cliVersion == "0.2.17")
        #expect(machine.daemon?.startedAt == Date(timeIntervalSince1970: now.timeIntervalSince1970 - 60))
        #expect(machine.daemon?.isShuttingDown == false && machine.metadataVersion == 4)
        #expect(try Machine(row: row(), keys: keys).daemon == nil)
    }

    @Test func theListHidesRevokedAndReplacedMachines() throws {
        let kept = try Machine(row: row(), keys: keys)
        let revoked = try Machine(row: row(["id": "m2", "revokedAt": 5]), keys: keys)
        let replaced = try Machine(row: row(["id": "m3", "replacedByMachineId": "m1"]), keys: keys)
        #expect(Machine.visible([revoked, kept, replaced]).map(\.id) == ["m1"])
    }

    @Test func renamingWritesTheWholeMetadataInTheMachinesOwnFormat() throws {
        let machine = try Machine(row: row(), keys: keys)
        let named = machine.renamedMetadata("  Studio  ")
        #expect(named["displayName"] == "Studio" && named["host"] == "mbp.local")
        #expect(machine.renamedMetadata("   ")["displayName"] == nil)
        let sealed = try machine.encodeMetadata(named)
        #expect(try ContentCipher.aesGCM(key: dataKey).decryptBase64(sealed) == named)

        let marker = Data(#"{"t":"plain","v":null}"#.utf8).base64EncodedString()
        let plain = try Machine(row: ["id": "p", "dataEncryptionKey": .string(marker),
                                      "metadata": .string(Data(#"{"t":"plain","v":{"host":"box"}}"#.utf8).base64EncodedString())], keys: nil)
        let encoded = try plain.encodeMetadata(["host": "box", "displayName": "Box"])
        #expect(try JSONValue.parse(Base64.decode(encoded)!) == ["t": "plain", "v": ["host": "box", "displayName": "Box"]])
    }

    @Test func realtimeUpdatesApplyNewerVersionsOnly() throws {
        var machine = try Machine(row: row(), keys: keys)
        let cipher = ContentCipher.aesGCM(key: dataKey)
        try machine.apply(update: ["metadata": ["value": .string(try cipher.encryptBase64(["host": "old"])), "version": 3]])
        #expect(machine.name == "mbp.local")
        try machine.apply(update: [
            "metadata": ["value": .string(try cipher.encryptBase64(["host": "new"])), "version": 5],
            "daemonState": ["value": .string(try cipher.encryptBase64(["status": "shutting-down"])), "version": 3],
            "active": false, "activeAt": .number(nowMs - 120_000), "revokedAt": .number(nowMs),
        ])
        #expect(machine.name == "new" && machine.metadataVersion == 5 && machine.daemon?.isShuttingDown == true)
        #expect(!machine.active && machine.revokedAt != nil && !machine.isOnline(at: now))
        machine.apply(activity: ["active": true, "activeAt": .number(nowMs)])
        #expect(machine.active && machine.activeAt == now)
    }

    @Test func detectedCLIsReadEveryResult() {
        let response: JSONValue = ["protocolVersion": 1, "results": [
            "cli.claude": ["ok": true, "checkedAt": 1, "data": ["available": true, "version": "2.1.3 (Claude Code)", "resolvedPath": "/usr/local/bin/claude"]],
            "cli.codex": ["ok": true, "checkedAt": 1, "data": ["available": false]],
            "cli.gemini": ["ok": false, "checkedAt": 1, "error": ["message": "boom"]],
            "tool.tmux": ["ok": true, "checkedAt": 1, "data": ["available": true, "version": "tmux 3.5a"]],
        ]]
        let detected = DetectedTools(response: response)
        #expect(detected?.agents == [
            .init(id: "claude", state: .installed(version: "2.1.3", path: "/usr/local/bin/claude")),
            .init(id: "codex", state: .missing),
            .init(id: "gemini", state: .unknown),
        ])
        #expect(detected?.tmux == .installed(version: "tmux 3.5a", path: nil))
        #expect(DetectedTools(response: ["error": "Method not found"]) == nil)
    }
}

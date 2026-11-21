import Foundation
import Testing
@testable import HappierKit

/// Mirrors `readActionableStaleSessionRunnerStatus` and `sessionRunnerRestart.ts` in the UI. The state
/// is the daemon's `daemon.sessionRunner.status.get` reply (it is not stored in session metadata).
@Suite struct SessionRunnerTests {
    private func state(versionState: String = "stale", eligible: Bool = true, disabledReason: JSONValue = .null,
                       machineId: String = "m1", runnerSource: String = "launch_spec") -> JSONValue {
        [
            "v": 1, "sessionId": "s1", "machineId": .string(machineId), "observedAtMs": 1,
            "runner": ["pid": 4242, "runtimeId": "0.2.13-dev.12", "processCommandHash": "abc",
                       "entrypointSource": .string(runnerSource), "startedBy": "daemon", "startingMode": "remote"],
            "daemon": ["currentEntrypointVersion": "0.2.13-dev.12-native", "currentEntrypointSource": "packaged_runtime"],
            "versionState": .string(versionState), "statusSource": "daemon_tracking",
            "plannedRestart": ["supported": true, "eligible": .bool(eligible), "disabledReason": disabledReason],
        ]
    }

    @Test func aStaleEligibleRunnerOffersARestart() {
        let stale = SessionRunner.staleRunner(sessionId: "s1", machineId: "m1", state: state())
        #expect(stale == StaleRunner(sessionId: "s1", machineId: "m1", expectedRunnerPid: 4242,
                                     expectedProcessCommandHash: "abc", expectedRunnerEntrypointIdentity: "0.2.13-dev.12"))
        #expect(stale.map(SessionRunner.restartRequest) == [
            "sessionId": "s1", "mode": "if_stale", "reason": "ui_stale_runner_banner",
            "expectedRunnerPid": 4242, "expectedProcessCommandHash": "abc", "expectedRunnerEntrypointIdentity": "0.2.13-dev.12",
        ])
    }

    @Test func nothingToOfferWhenCurrentIneligibleOrUnknown() {
        #expect(SessionRunner.staleRunner(sessionId: "s1", machineId: "m1", state: state(versionState: "current")) == nil)
        #expect(SessionRunner.staleRunner(sessionId: "s1", machineId: "m1", state: state(eligible: false)) == nil)
        #expect(SessionRunner.staleRunner(sessionId: "s1", machineId: "m1", state: state(disabledReason: "turn_in_progress")) == nil)
        #expect(SessionRunner.staleRunner(sessionId: "s1", machineId: "m1", state: state(machineId: "other")) == nil)
        #expect(SessionRunner.staleRunner(sessionId: "s1", machineId: "m1", state: state(runnerSource: "unknown")) == nil)
        #expect(SessionRunner.staleRunner(sessionId: "s1", machineId: "m1", state: ["path": "/x"]) == nil)
    }

    @Test func restartResultsMapToWhatTheUserCanDo() {
        #expect(SessionRunner.outcome(["ok": true, "status": "restarted", "sessionId": "s1"]) == .restarted)
        #expect(SessionRunner.outcome(["ok": true, "status": "already_current", "sessionId": "s1"]) == .restarted)
        #expect(SessionRunner.outcome(["ok": false, "status": "busy", "sessionId": "s1"]) == .busy)
        #expect(SessionRunner.outcome(["ok": false, "status": "spawn_failed", "sessionId": "s1"]) == .failed)
        #expect(SessionRunner.outcome(["unexpected": true]) == .failed)
    }
}

/// The relay only forwards session writes over a machine (`stop-session`, runner restart, agent
/// switch) with a `session.write` proof naming the session (`rpcHandler.ts`); the daemon checks
/// that it names the session in the params (`machineRpcAuthorization.ts`).
@Suite struct MachineRPCCallTests {
    @Test func sessionWritesCarryTheProofForTheSessionInTheirParams() {
        for method in ["stop-session", "daemon.sessionRunner.restart", "session.agentTransition"] {
            #expect(MachineRPCCall.payload(machineId: "m1", method: method, params: ["sessionId": "s1"], encoded: "enc", timeoutMs: 30000) == [
                "method": .string("m1:\(method)"), "params": "enc", "timeoutMs": 30000,
                "authorization": ["kind": "session.write", "sessionId": "s1"],
            ])
        }
        #expect(MachineRPCCall.payload(machineId: "m1", method: "daemon.filesystem.listRoots", params: ["sessionId": "s1"], encoded: "enc",
                                       timeoutMs: 30000)["authorization"] == nil)
    }

    /// The same methods as the protocol's list, so the two can't drift apart again.
    @Test func theSessionWriteMethodsAreTheProtocols() throws {
        let rpc = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../../packages/protocol/src/rpc.ts").standardized
        let source = try String(contentsOf: rpc, encoding: .utf8)
        let list = try #require(source.firstMatch(of: /SOCKET_RPC_SESSION_WRITE_AUTHORIZATION_METHODS = new Set<string>\(\[([^\]]*)\]\)/)?.1)
        let names = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let methods = try names.map { name -> String in
            let key = String(name.dropFirst("RPC_METHODS.".count))
            let regex = try Regex("\\b\(key): '([^']+)'")
            return try #require(source.firstMatch(of: regex)?.output[1].substring).description
        }
        #expect(!methods.isEmpty)
        #expect(Set(methods) == MachineRPCCall.sessionWriteMethods)
    }
}

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

/// The server only relays session-scoped machine RPCs (`stop-session`, runner restart) with a
/// `session.write` authorization context (`rpcHandler.ts`).
@Suite struct MachineRPCCallTests {
    @Test func sessionScopedCallsCarryTheAuthorizationContext() {
        #expect(MachineRPCCall.payload(machineId: "m1", method: "stop-session", params: "enc", timeoutMs: 30000, authorizingSession: "s1") == [
            "method": "m1:stop-session", "params": "enc", "timeoutMs": 30000,
            "authorization": ["kind": "session.write", "sessionId": "s1"],
        ])
        #expect(MachineRPCCall.payload(machineId: "m1", method: "daemon.filesystem.listRoots", params: "enc", timeoutMs: 30000, authorizingSession: nil)["authorization"] == nil)
    }
}

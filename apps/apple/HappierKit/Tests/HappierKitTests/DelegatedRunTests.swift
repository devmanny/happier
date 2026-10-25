import Foundation
import Testing
@testable import HappierKit

/// Happier execution runs started from a session (`execution.run.list`, `ExecutionRunPublicStateSchema`).
@Suite struct DelegatedRunTests {
    /// As the daemon returned this session's own Kimi delegation.
    private let kimiFields: [String: JSONValue] = [
        "runId": "run_a133", "callId": "subagent_run_1958", "sidechainId": "subagent_run_1958", "intent": "delegate",
        "backendTarget": ["kind": "builtInAgent", "agentId": "kimi"],
        "launchOrigin": ["kind": "session", "sessionId": "s"], "permissionMode": "yolo", "retentionPolicy": "ephemeral",
        "runClass": "bounded", "ioMode": "request_response", "status": "succeeded",
        "startedAtMs": 1_000, "finishedAtMs": 413_000,
    ]
    private var kimi: JSONValue { .object(kimiFields) }

    @Test func aFinishedDelegationReadsWithItsAgentAndDuration() throws {
        let run = try #require(DelegatedRun(json: kimi))
        #expect(run.id == "run_a133" && run.agentId == "kimi" && run.intent == "delegate")
        #expect(run.status == "succeeded" && !run.isActive && !run.failed)
        #expect(run.startedAt == Date(timeIntervalSince1970: 1) && run.finishedAt == Date(timeIntervalSince1970: 413))
    }

    @Test func activityFollowsTheProtocolRule() throws {
        var running = kimiFields
        running["status"] = "running"
        running["finishedAtMs"] = nil
        #expect(try #require(DelegatedRun(json: .object(running))).isActive)
        // A long-lived run between turns is retained but idle.
        running["runClass"] = "long_lived"
        running["turnInFlight"] = false
        #expect(try #require(DelegatedRun(json: .object(running))).isActive == false)
    }

    @Test func titlesAndFailuresAndConfiguredBackends() throws {
        var run = kimiFields
        run["display"] = ["title": "Review the diff"]
        run["status"] = "failed"
        run["error"] = ["code": "execution_run_failed", "message": "Kimi exited"]
        run["backendTarget"] = ["kind": "configuredAcpBackend", "backendId": "my-acp"]
        let parsed = try #require(DelegatedRun(json: .object(run)))
        #expect(parsed.title == "Review the diff" && parsed.failed && parsed.errorMessage == "Kimi exited")
        #expect(parsed.agentId == nil && parsed.backendId == "my-acp")
        #expect(DelegatedRun(json: ["status": "running"]) == nil)
    }

    @Test func theListIsNewestFirst() {
        var older = kimiFields
        older["runId"] = "old"
        older["startedAtMs"] = 500
        let runs = DelegatedRun.list(["runs": [.object(older), kimi, ["junk": true]]])
        #expect(runs.map(\.id) == ["run_a133", "old"])
    }
}

import Foundation
import Testing
@testable import HappierKit

@Suite struct BackgroundActivityTests {
    @Test func sessionsCarryTheirBackgroundCountLive() throws {
        var session = try Session(row: ["id": "s", "encryptionMode": "plain", "runtimeActivityState": "active",
                                        "runtimeActivityActiveCount": 2, "runtimeActivityRevision": 7], keys: nil)
        #expect(session.backgroundActivityCount == 2 && session.runtimeActivityRevision == 7)
        try session.apply(update: ["t": "update-session", "id": "s", "runtimeActivityState": "idle",
                                   "runtimeActivityActiveCount": 0, "runtimeActivityRevision": 8])
        #expect(session.backgroundActivityCount == 0 && session.runtimeActivityRevision == 8)
    }

    @Test func backgroundCommandsReadFromTheirRecords() throws {
        let running = try #require(BackgroundCommand(payload: [
            "v": 1, "taskId": "bk1", "kind": "command", "status": "running", "label": "npm run dev",
            "startedAt": 1_000, "updatedAt": 2_000,
        ]))
        #expect(running.isLive && running.label == "npm run dev" && running.startedAt == Date(timeIntervalSince1970: 1))
        let done = try #require(BackgroundCommand(payload: ["v": 1, "taskId": "bk2", "kind": "command", "status": "succeeded",
                                                         "updatedAt": 3_000, "endedAt": 3_000, "summary": "exit 0"]))
        #expect(!done.isLive && done.summary == "exit 0" && done.label == nil)
        #expect(BackgroundCommand(payload: ["v": 1, "status": "running"]) == nil)
    }

    /// A workflow (Claude's `Workflow` tool) is counted in the background like a subagent, but it is
    /// no subagent tool call: what the list shows of it comes from its `workflow_run.v1` record.
    @Test func workflowRunsReadFromTheirRecords() throws {
        func snapshot(_ status: String, completedAgents: Int = 2, projection: Int = 1) -> JSONValue {
            ["v": 1, "projectionVersion": .number(Double(projection)), "runId": "wjkotk88b", "backendId": "claude",
             "title": "Adversarially review the session list changes", "status": .string(status), "recordRevision": "r1",
             "startedAt": 1_000, "updatedAt": 5_000, "totalAgents": 6, "completedAgents": .number(Double(completedAgents)),
             "failedAgents": 1, "phases": [], "agents": []]
        }
        let running = try #require(WorkflowRun(payload: snapshot("active")))
        #expect(running.isLive && running.id == "wjkotk88b" && running.title == "Adversarially review the session list changes")
        #expect(running.totalAgents == 6 && running.completedAgents == 2 && running.startedAt == Date(timeIntervalSince1970: 1))
        // Waiting on a person or not known yet still counts as going, as on the web.
        #expect(WorkflowRun(payload: snapshot("blocked"))?.isLive == true)
        #expect(WorkflowRun(payload: snapshot("unknown"))?.isLive == true)
        let done = try #require(WorkflowRun(payload: snapshot("complete", completedAgents: 6)))
        #expect(!done.isLive && !done.failed)
        #expect(WorkflowRun(payload: snapshot("failed"))?.failed == true)
        #expect(WorkflowRun(payload: snapshot("stopped"))?.isLive == false)
        // Another projection of the record isn't read as this one.
        #expect(WorkflowRun(payload: snapshot("active", projection: 2)) == nil)
        #expect(WorkflowRun(payload: ["v": 1, "projectionVersion": 1, "status": "active"]) == nil)
    }
}

@Suite struct SubagentSettlingTests {
    @Test func theDaemonsCountOverridesAnUnreadThread() throws {
        let running = Subagent(id: "t", title: "Explore", kind: nil, startedAt: .now, status: .running, lastActivityAt: nil)
        let idle = try Session(row: ["id": "s", "encryptionMode": "plain", "runtimeActivityState": "idle",
                                     "runtimeActivityActiveCount": 0, "runtimeActivityRevision": 9], keys: nil)
        let busy = try Session(row: ["id": "s", "encryptionMode": "plain", "runtimeActivityState": "active",
                                     "runtimeActivityActiveCount": 1, "runtimeActivityRevision": 9], keys: nil)
        let untracked = try Session(row: ["id": "s", "encryptionMode": "plain"], keys: nil)
        #expect(running.settled(by: idle).status == .finished)
        #expect(running.settled(by: busy).status == .running)
        #expect(running.settled(by: untracked).status == .running)
    }
}

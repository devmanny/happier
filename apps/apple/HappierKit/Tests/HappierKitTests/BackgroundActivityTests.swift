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

import Foundation
import Testing
@testable import HappierKit

/// The goal the agent keeps pursuing across turns (Codex goals, Claude `/goal`).
@Suite struct SessionGoalTests {
    @Test func readsTheGoalFromTheWorkState() {
        let metadata: JSONValue = ["sessionWorkStateV1": [
            "v": 1, "backendId": "codex", "updatedAt": 5, "primaryItemId": "goal:t1",
            "items": [
                ["id": "todo:1", "kind": "todo", "status": "active", "title": "Write tests", "updatedAt": 5],
                ["id": "goal:t1", "kind": "goal", "status": "paused", "title": "Ship the native app", "updatedAt": 5],
            ],
        ]]
        #expect(SessionGoal.current(in: metadata) == SessionGoal(objective: "Ship the native app", status: .paused))
    }

    @Test func fallsBackToTheLegacyGoalAndHidesFinishedOnes() {
        #expect(SessionGoal.current(in: ["sessionGoalV1": ["objective": "Fix CI", "status": "active"]])
            == SessionGoal(objective: "Fix CI", status: .active))
        let done: JSONValue = ["sessionWorkStateV1": ["v": 1, "backendId": "claude", "updatedAt": 1,
                                                      "items": [["id": "g", "kind": "goal", "status": "complete", "title": "Done", "updatedAt": 1]]]]
        #expect(SessionGoal.current(in: done)?.isOngoing == false)
        #expect(SessionGoal.current(in: ["path": "/a"]) == nil)
    }

    @Test func readsWhatTheRunningAgentCanDo() {
        let state: JSONValue = ["capabilities": ["sessionGoalSetSupported": true, "sessionGoalClearSupported": false]]
        #expect(SessionGoal.controls(agentState: state) == SessionGoal.Controls(canSet: true, canClear: false))
        #expect(SessionGoal.controls(agentState: .null) == SessionGoal.Controls(canSet: false, canClear: false))
    }
}

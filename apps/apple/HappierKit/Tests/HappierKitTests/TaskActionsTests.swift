import Foundation
import Testing
@testable import HappierKit

/// A task's detail offers only what would change something: never the current assignee, a start
/// of what already runs, or a schedule when a start is pending; it shows that state instead.
@Suite struct TaskActionsTests {
    private func task(assignee: JSONValue = ["kind": "agent", "agentId": "mateo", "name": "Mateo", "emoji": "🤖"],
                      status: String = "todo", threads: [String] = [], source: String? = nil,
                      occurrences: [JSONValue] = [], scheduledAt: Double? = nil) -> AgentTask {
        var json: [String: JSONValue] = [
            "v": 1, "id": "t", "title": "Ayudarle a Iram a publicar su juego", "status": .string(status), "assignee": assignee,
            "threads": .array(threads.map(JSONValue.string)), "log": [], "createdAt": 0, "updatedAt": 0,
        ]
        if let source { json["source"] = ["kind": "session", "sessionId": .string(source)] }
        if !occurrences.isEmpty { json["occurrences"] = .array(occurrences) }
        if let scheduledAt { json["scheduledStartV1"] = ["at": .number(scheduledAt), "timezone": "America/Mexico_City"] }
        return AgentTask(json: .object(json))!
    }

    @Test func openedFromTheSessionWorkingItShowsThatInsteadOfOfferingIt() {
        let actions = task(status: "in_progress", threads: ["tapagol"]).availableActions(from: .session("tapagol"))
        #expect(!actions.offersThisSession)
        #expect(actions.worksHere && actions.runsHere)
        #expect(!actions.offersStartNow && !actions.offersSchedule)
        #expect(actions.runningSessionId == "tapagol")
    }

    @Test func aSessionTheTaskOnlyCameFromIsNotOfferedAgainButCanStillStartIt() {
        let actions = task(source: "origin").availableActions(from: .session("origin"))
        #expect(!actions.offersThisSession)
        #expect(!actions.worksHere && !actions.runsHere)
        #expect(actions.offersStartNow && actions.offersSchedule)
    }

    @Test func fromAnotherSessionThatSessionIsADestinationButTheRunningOneIsNotRestarted() {
        let actions = task(status: "in_progress", threads: ["tapagol"]).availableActions(from: .session("other"))
        #expect(actions.offersThisSession)
        #expect(!actions.worksHere && !actions.runsHere)
        #expect(actions.runningSessionId == "tapagol")
        #expect(!actions.offersStartNow && !actions.offersSchedule)
    }

    @Test func fromTheListOrALinkThereIsNoThisSession() {
        for origin in [AgentTask.Origin.list, .link] {
            let actions = task().availableActions(from: origin)
            #expect(!actions.offersThisSession && !actions.worksHere)
            #expect(actions.offersStartNow && actions.offersSchedule)
        }
    }

    @Test func theCurrentAssigneeIsNotOfferedAgain() {
        let actions = task().availableActions(from: .list)
        #expect(!actions.offers(.agent(id: "mateo", name: "Mateo", emoji: nil)))
        #expect(actions.offers(.agent(id: "tomas", name: "Tomás", emoji: nil)))
        #expect(actions.offers(.user))
        let mine = task(assignee: ["kind": "user"]).availableActions(from: .list)
        #expect(!mine.offers(.user))
        #expect(!mine.offersStartNow && !mine.offersSchedule, "nothing to start for you")
        let here = task(assignee: ["kind": "session", "sessionId": "x"]).availableActions(from: .session("x"))
        #expect(!here.offersThisSession && here.worksHere && !here.runsHere)
        #expect(here.offersStartNow, "assigned here but not sent yet")
    }

    @Test func aPendingStartIsShownNotOfferedAgain() {
        let actions = task(scheduledAt: 1_900_000_000_000).availableActions(from: .list)
        #expect(!actions.offersSchedule)
        #expect(actions.pendingStart?.at == 1_900_000_000_000)
        #expect(actions.offersStartNow)
    }

    @Test func aRunningOccurrenceRunsInItsSession() {
        let occurrence: JSONValue = ["id": "o1", "startedAt": 1, "status": "running", "sessionId": "daily"]
        let done: JSONValue = ["id": "o0", "startedAt": 0, "status": "completed", "sessionId": "yesterday"]
        let actions = task(occurrences: [done, occurrence]).availableActions(from: .session("daily"))
        #expect(actions.runningSessionId == "daily")
        #expect(actions.runsHere && actions.worksHere && !actions.offersThisSession)
        #expect(!actions.offersStartNow && !actions.offersSchedule)
        let finished = task(occurrences: [done]).availableActions(from: .session("yesterday"))
        #expect(!finished.runsHere && finished.runningSessionId == nil)
        #expect(finished.offersStartNow)
    }

    @Test func aDoneTaskOffersNoStart() {
        let actions = task(status: "done", threads: ["s"]).availableActions(from: .session("s"))
        #expect(!actions.offersStartNow && !actions.offersSchedule && !actions.runsHere)
    }
}

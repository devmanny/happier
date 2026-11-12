import Foundation
import Testing
@testable import HappierKit

/// The agent card opened from the composer's status pill: what it lists and in which order.
@Suite struct AgentCardTests {
    private let now = 1_000_000_000.0

    private func thread(_ sessionId: String, minutesAgo: Double, title: String? = nil) -> AgentMemory.Now {
        AgentMemory.Now(sessionId: sessionId, text: "doing \(sessionId)", title: title, updatedAt: now - minutesAgo * 60_000)
    }

    private func task(_ id: String, agent: String? = nil, session: String? = nil, threads: [String] = [],
                      status: AgentTask.Status = .todo, dueAt: Double? = nil, createdAt: Double = 0) -> AgentTask {
        var task = AgentTask(id: id, title: id, assignee: agent.map { .agent(id: $0, name: nil, emoji: nil) } ?? session.map { .session(id: $0, title: nil) } ?? .user,
                             status: status, now: createdAt)
        task.threads = threads
        task.dueAt = dueAt
        return task
    }

    /// A session from the list: `row` adds what decides its state, `metadata` its title and rest.
    private func session(_ id: String, row: [String: JSONValue] = [:], metadata: JSONValue = [:]) throws -> Session {
        var fields: [String: JSONValue] = [
            "id": .string(id), "encryptionMode": "plain", "metadataVersion": 1, "active": true, "activeAt": .number(now),
            "metadata": .string(String(decoding: try metadata.encoded(), as: UTF8.self)),
        ]
        fields.merge(row) { $1 }
        return try Session(row: .object(fields), keys: nil)
    }

    // MARK: Now

    @Test func thisSessionLeadsTheNowRowsAndTheOthersFollowNewestFirst() {
        let memory = AgentMemory(now: [thread("b", minutesAgo: 12), thread("here", minutesAgo: 60), thread("c", minutesAgo: 120)])
        let rows = AgentCard.nowRows(memory, sessionId: "here", now: now, session: { _ in nil })
        #expect(rows.map(\.sessionId) == ["here", "b", "c"])
        #expect(rows.map(\.isThisSession) == [true, false, false])
    }

    @Test func aNowRowTakesItsStateFromTheSessionAndItsPlaceFromTheRecordThenTheSessionList() throws {
        let memory = AgentMemory(now: [thread("a", minutesAgo: 1, title: "Publish TAPAGOL"), thread("b", minutesAgo: 2),
                                       thread("c", minutesAgo: 3), thread("d", minutesAgo: 4), thread("e", minutesAgo: 5),
                                       thread("f", minutesAgo: 6), thread("gone", minutesAgo: 7)])
        let sessions = Dictionary(uniqueKeysWithValues: try [
            session("a", row: ["latestTurnStatus": "in_progress", "latestTurnStatusObservedAt": .number(now)]),
            session("b", row: ["pendingPermissionRequestCount": 1], metadata: ["summary": ["text": "Invoice La Chata", "updatedAt": 1]]),
            session("c", metadata: ["path": "/w/radar"]),
            session("d", row: ["latestTurnStatus": "failed"]),
            session("e", row: ["active": false]),
            session("f", row: ["active": false],
                    metadata: ["lifecycleStateSince": 1, "sessionRestV1": ["v": 1, "reason": "idle", "at": 2]]),
        ].map { ($0.id, $0) })
        let rows = AgentCard.nowRows(memory, sessionId: "x", now: now, session: { sessions[$0] })
        #expect(rows.map(\.state) == [.working, .waiting, .online, .inactive, .inactive, .resting, .inactive])
        #expect(rows.map(\.place) == ["Publish TAPAGOL", "Invoice La Chata", "radar", "Unknown", "Unknown", "Unknown", nil])
    }

    @Test func howLongAgoIsBucketedLikeTheMockup() {
        func ago(_ minutes: Double) -> AgentCard.Ago { AgentCard.Ago(ms: now - minutes * 60_000, now: now) }
        #expect(ago(0.4) == .justNow)
        #expect(ago(1) == .minutes(1))
        #expect(ago(59) == .minutes(59))
        #expect(ago(60) == .hours(1))
        #expect(ago(47 * 60) == .hours(47))
        #expect(ago(48 * 60) == .days(2))
        // A clock a little ahead of the server's still reads as now.
        #expect(AgentCard.Ago(ms: now + 30_000, now: now) == .justNow)
        #expect(AgentCard.Ago.minutes(4).text == "4 min ago")
        #expect(AgentCard.Ago.hours(2).text == "2 h ago")
    }

    // MARK: Tasks

    @Test func theAgentsOpenTasksListThisSessionsFirstThenSoonestDue() {
        let tasks = [
            task("later", agent: "mateo", dueAt: 900),
            task("soon", agent: "mateo", dueAt: 100),
            task("here", agent: "mateo", threads: ["s1"], dueAt: 5_000),
            task("done", agent: "mateo", status: .done),
            task("someone else", agent: "leo", threads: ["s1"]),
            task("mine", threads: ["s1"]),
        ]
        let list = AgentCard.tasks(tasks, agentId: "mateo", sessionId: "s1", lingering: [])
        #expect(list.tasks.map(\.id) == ["here", "soon", "later"])
        #expect(list.openCount == 3)
        #expect(!list.hasMore)
    }

    @Test func aTaskJustCompletedWithTheCircleStaysUntilItsUndoTimePasses() {
        let tasks = [task("a", agent: "mateo", status: .done), task("b", agent: "mateo")]
        let list = AgentCard.tasks(tasks, agentId: "mateo", sessionId: "s1", lingering: ["a"])
        #expect(Set(list.tasks.map(\.id)) == ["a", "b"])
        #expect(list.openCount == 1)
    }

    // MARK: The agent's profile

    @Test func theProfileListsTheAgentsBacklogByStatusInWorkOrderSoonestDueFirst() {
        var archived = task("archived", agent: "mateo")
        archived.archivedAt = 5
        let tasks = [
            task("review", agent: "mateo", status: .inReview),
            task("todo later", agent: "mateo", dueAt: 900),
            task("todo soon", agent: "mateo", dueAt: 100),
            task("doing", agent: "mateo", status: .inProgress),
            task("stuck", agent: "mateo", status: .blocked),
            task("finished", agent: "mateo", status: .done),
            archived,
            task("leo's", agent: "leo"),
            task("a session's", session: "s1"),
        ]
        let backlog = AgentCard.backlog(tasks, agentId: "mateo")
        #expect(backlog.map(\.status) == [.todo, .inProgress, .blocked, .inReview, .done])
        #expect(backlog.first?.tasks.map(\.id) == ["todo soon", "todo later"])
        #expect(backlog.flatMap(\.tasks).count == 6)
        // Nothing in a status, no group for it.
        #expect(AgentCard.backlog([task("doing", agent: "mateo", status: .inProgress)], agentId: "mateo").map(\.status) == [.inProgress])
    }

    @Test func theProfileIsSelectedInTheSidebarLikeASessionButNeverReadAsOne() {
        let selection = AgentProfile.selection(id: "a-mateo")
        #expect(AgentProfile.id(inSelection: selection) == "a-mateo")
        #expect(AgentProfile.id(inSelection: "cmuenhmmr0isvpe01pzj907ri") == nil)
        #expect(AgentProfile.id(inSelection: nil) == nil)
        #expect(selection != "a-mateo")
    }

    @Test func theCardShowsAFewTasksAndSaysThereAreMore() {
        let tasks = (0..<5).map { task("t\($0)", agent: "mateo", createdAt: Double($0)) }
        let list = AgentCard.tasks(tasks, agentId: "mateo", sessionId: "s1", lingering: [])
        #expect(list.tasks.map(\.id) == ["t0", "t1", "t2"])
        #expect(list.openCount == 5)
        #expect(list.hasMore)
    }

    @Test func withoutAnAgentTheTasksAreThoseOfThisSession() {
        let tasks = [task("assigned", session: "s1"), task("worked", threads: ["s1"]), task("elsewhere", threads: ["s2"]),
                     task("agent's", agent: "mateo")]
        let list = AgentCard.tasks(tasks, agentId: nil, sessionId: "s1", lingering: [])
        #expect(Set(list.tasks.map(\.id)) == ["assigned", "worked"])
    }

    // MARK: Memory and sections

    @Test func recentMemoryIsTheNewestThreeJournalEntries() {
        let journal = (0..<5).map { AgentMemory.JournalEntry(id: "j\($0)", day: "2026-11-07", sessionId: nil, text: "note \($0)", at: Double($0), version: 0) }
        let memory = AgentMemory(journal: journal.sorted { $0.at > $1.at })
        #expect(AgentCard.recentMemory(memory).map(\.id) == ["j4", "j3", "j2"])
        #expect(AgentCard.recentMemory(nil).isEmpty)
    }

    @Test func aSessionWithAnAgentShowsEverySectionInTheMockupsOrder() {
        let sections = AgentCard.sections(hasAgent: true, profileKnown: true, hasDescription: true)
        #expect(sections == [.now, .tasks, .memory, .description, .thisSession, .editAgent])
    }

    @Test func anAgentWhoseProfileIsntHereCantBeEditedOrDescribed() {
        #expect(AgentCard.sections(hasAgent: true, profileKnown: false, hasDescription: false) == [.now, .tasks, .memory, .thisSession])
        #expect(AgentCard.sections(hasAgent: true, profileKnown: true, hasDescription: false) == [.now, .tasks, .memory, .thisSession, .editAgent])
    }

    @Test func aSessionWithoutAnAgentShowsItsStateItsTasksAndItsControls() {
        #expect(AgentCard.sections(hasAgent: false, profileKnown: false, hasDescription: false) == [.sessionState, .tasks, .thisSession])
    }

    @Test func theSessionLineJoinsModelFolderAndMachineSkippingWhatIsUnknown() {
        #expect(AgentCard.sessionLine(model: "Opus 5.5", folder: "~/Projects/Happier", machine: "Mac mini") == "Opus 5.5 · ~/Projects/Happier · Mac mini")
        #expect(AgentCard.sessionLine(model: "Opus 5.5", folder: nil, machine: " ") == "Opus 5.5")
    }
}

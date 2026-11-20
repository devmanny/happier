import Foundation
import Testing
@testable import HappierKit

/// The agents atop the session list: their open sessions, what works and what needs you, the
/// weekly usage of each agent's own account, and their synced order.
@Suite struct AgentRosterTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func profile(_ id: String, _ name: String, provider: String = "claude", configDir: String? = nil) -> AgentProfile {
        AgentProfile(id: id, name: name, providerId: provider, account: .init(label: name, configDir: configDir), updatedAt: 0)
    }

    private enum Activity { case idle, working, permission, question, failed, unread }

    private func session(_ id: String, agent: String?, flavor: String = "claude", active: Bool = true, archived: Bool = false,
                         activity: Activity = .idle, unread: Bool = false, lastActiveMs: Double = 1_000) throws -> Session {
        var metadata: [String: JSONValue] = ["path": "/Users/manny/Projects/app", "name": .string(id), "flavor": .string(flavor)]
        if let agent { metadata["agentIdentityV1"] = ["v": 1, "id": .string(agent), "name": .string(agent.capitalized)] }
        var row: [String: JSONValue] = [
            "id": .string(id), "encryptionMode": "plain", "metadataVersion": 1, "active": .bool(active), "updatedAt": 10,
            "meaningfulActivityAt": .number(lastActiveMs),
            "metadata": .string(String(decoding: try JSONValue.object(metadata).encoded(), as: UTF8.self)),
        ]
        if archived { row["archivedAt"] = 5 }
        switch activity {
        case .idle: break
        case .working:
            row["latestTurnStatus"] = "in_progress"
            row["latestTurnStatusObservedAt"] = .number(now.timeIntervalSince1970 * 1000 - 5_000)
        case .permission: row["pendingPermissionRequestCount"] = 1
        case .question: row["pendingUserActionRequestCount"] = 1
        case .failed: row["latestTurnStatus"] = "failed"
        case .unread: row["unreadSince"] = 7
        }
        if unread { row["unreadSince"] = 7 }
        return try Session(row: .object(row), keys: nil)
    }

    private func reading(provider: String? = "claude", weeklyUsed: Double?, fetchedAtMs: Double) -> ProviderUsage {
        var meters: [JSONValue] = [["meterId": "five_hour", "label": "5h", "utilizationPct": 90, "windowDurationMs": 18_000_000, "status": "ok"]]
        if let weeklyUsed {
            meters.append(["meterId": "seven_day", "label": "Week", "utilizationPct": .number(weeklyUsed),
                           "windowDurationMs": 604_800_000, "status": "ok"])
        }
        var snapshot: [String: JSONValue] = ["v": 1, "fetchedAtMs": .number(fetchedAtMs), "meters": .array(meters)]
        if let provider { snapshot["providerId"] = .string(provider) }
        return ProviderUsage(snapshot: .object(snapshot))!
    }

    @Test func itsLineSaysWhatTheNewestWorkingSessionIsOrWhenItLastDidSomething() throws {
        let julian = profile("julian", "Julián")
        let summary = { (sessions: [Session]) in
            AgentRoster.summary(of: julian, sessions: sessions, context: SessionListFilter.Context(tasks: []), now: self.now, usage: { _ in nil })
        }
        let working = summary([
            try session("old-work", agent: "julian", activity: .working, lastActiveMs: 1_000),
            try session("new-work", agent: "julian", activity: .working, lastActiveMs: 3_000),
            try session("idle", agent: "julian", lastActiveMs: 5_000),
        ])
        #expect(working.latestWorking?.id == "new-work")
        #expect(working.lastActivity == Date(timeIntervalSince1970: 5))
        let idle = summary([try session("idle", agent: "julian", lastActiveMs: 4_000)])
        #expect(idle.latestWorking == nil)
        #expect(idle.lastActivity == Date(timeIntervalSince1970: 4))
        #expect(summary([]).lastActivity == nil)
    }

    @Test func anAgentsSessionsAreItsRunningUnarchivedOnes() throws {
        let tomas = profile("tomas", "Tomás")
        let sessions = [
            try session("mine", agent: "tomas", lastActiveMs: 1_000),
            try session("newer", agent: "tomas", lastActiveMs: 2_000),
            try session("stopped", agent: "tomas", active: false),
            try session("archived", agent: "tomas", archived: true),
            try session("other", agent: "julian"),
            try session("plain", agent: nil),
        ]
        #expect(AgentRoster.openSessions(of: tomas, in: sessions).map(\.id) == ["newer", "mine"])
    }

    @Test func countsOpenWorkingAndWhatNeedsYouByTheListFiltersRule() throws {
        let tomas = profile("tomas", "Tomás")
        let sessions = [
            try session("working", agent: "tomas", activity: .working),
            try session("asks", agent: "tomas", activity: .permission),
            try session("unread", agent: "tomas", activity: .unread),
            try session("tasked", agent: "tomas"),
            try session("quiet", agent: "tomas"),
            // Stopped but unread: not open, so it doesn't count.
            try session("stopped", agent: "tomas", active: false, activity: .unread),
        ]
        let task = AgentTask(json: ["v": 1, "id": "t", "title": "t", "status": "todo", "assignee": ["kind": "user"],
                                    "threads": ["tasked"], "log": [], "createdAt": 0, "updatedAt": 0])!
        let context = SessionListFilter.Context(tasks: [task])
        let summary = try #require(AgentRoster.summaries(profiles: [tomas], order: [], sessions: sessions, context: context,
                                                         now: now, usage: { _ in nil }).first)
        #expect(summary.open == 5)
        #expect(summary.working == 1)
        // The same owner the "Needs me" filter uses: a request, an unread message, an open task.
        let needing = sessions.filter { $0.active && context.needsAttention($0, now: now) }.count
        #expect(summary.needsYou == needing)
        #expect(summary.needsYou == 3)
        #expect(AgentRoster.state(of: sessions[0], context: context, now: now) == .working)
        #expect(AgentRoster.state(of: sessions[1], context: context, now: now) == .needsYou)
        #expect(AgentRoster.state(of: sessions[3], context: context, now: now) == .needsYou)
        #expect(AgentRoster.state(of: sessions[4], context: context, now: now) == .idle)
    }

    @Test func weeklyUsageIsTheNewestReadingOfTheAgentsOwnAccount() throws {
        // Two Claude agents on two Claude accounts: Tomás's newer reading is never Julián's.
        let tomas = profile("tomas", "Tomás", configDir: "~/.claude-tomas")
        let julian = profile("julian", "Julián", configDir: "~/.claude")
        let sessions = [
            try session("t-old", agent: "tomas"), try session("t-new", agent: "tomas"),
            try session("j", agent: "julian"), try session("j-stopped", agent: "julian", active: false),
        ]
        let readings: [String: ProviderUsage] = [
            "t-old": reading(weeklyUsed: 40, fetchedAtMs: 1_000),
            "t-new": reading(weeklyUsed: 15, fetchedAtMs: 3_000),
            "j": reading(weeklyUsed: 60, fetchedAtMs: 2_000),
            // A stopped session ran on the same account; its newer reading counts.
            "j-stopped": reading(weeklyUsed: 70, fetchedAtMs: 2_500),
        ]
        let usage = { (session: Session) in readings[session.id] }
        #expect(AgentRoster.weeklyUsage(of: tomas, sessions: sessions, usage: usage)?.usedPercent == 15)
        #expect(AgentRoster.weeklyUsage(of: julian, sessions: sessions, usage: usage)?.usedPercent == 70)
    }

    @Test func weeklyUsagePicksTheWeeklyMeterAndIgnoresOtherProvidersAndReadingsWithoutOne() throws {
        let leo = profile("leo", "Leo", provider: "kimi")
        let tomas = profile("tomas", "Tomás")
        let sessions = [
            try session("a", agent: "tomas"), try session("b", agent: "tomas"),
            // Switched to another engine: its reading is that provider's account.
            try session("c", agent: "tomas", flavor: "codex"),
            try session("leo", agent: "leo", flavor: "kimi"),
        ]
        let readings: [String: ProviderUsage] = [
            "a": reading(weeklyUsed: 30, fetchedAtMs: 1_000),
            "b": reading(weeklyUsed: nil, fetchedAtMs: 2_000),
            "c": reading(provider: "codex", weeklyUsed: 99, fetchedAtMs: 3_000),
        ]
        let usage = { (session: Session) in readings[session.id] }
        let weekly = AgentRoster.weeklyUsage(of: tomas, sessions: sessions, usage: usage)
        #expect(weekly?.id == "seven_day")
        #expect(weekly?.usedPercent == 30)
        #expect(AgentRoster.weeklyUsage(of: leo, sessions: sessions, usage: usage) == nil)
    }

    @Test func usageIsReadFromTheAgentsNewestSessionWithRecordsOnItsProvider() throws {
        func withRecords(_ session: Session) -> Session {
            var session = session
            session.metadata = .object((session.metadata.objectValue ?? [:]).merging(
                ["providerAccountUsageRefsV1": ["recordIds": .array([.string("rec-" + session.id)])]]) { $1 })
            return session
        }
        let tomas = profile("tomas", "Tomás")
        let sessions = [
            withRecords(try session("old", agent: "tomas", active: false, lastActiveMs: 1_000)),
            try session("newest-without", agent: "tomas", lastActiveMs: 5_000),
            withRecords(try session("codex", agent: "tomas", flavor: "codex", lastActiveMs: 4_000)),
            withRecords(try session("archived", agent: "tomas", archived: true, lastActiveMs: 6_000)),
            withRecords(try session("other", agent: "julian", lastActiveMs: 7_000)),
            withRecords(try session("recent", agent: "tomas", lastActiveMs: 3_000)),
        ]
        #expect(AgentRoster.sessionToReadUsage(of: tomas, sessions: sessions)?.id == "recent")
        #expect(AgentRoster.sessionToReadUsage(of: profile("leo", "Leo"), sessions: sessions) == nil)
    }

    @Test func theSavedOrderComesFirstAndNewAgentsFollowByName() {
        let profiles = [profile("a", "Mateo"), profile("b", "Julián"), profile("c", "Tomás"), profile("d", "Leo"), profile("e", "Ana")]
        let ordered = AgentRoster.ordered(profiles, by: ["c", "gone", "a"])
        #expect(ordered.map(\.name) == ["Tomás", "Mateo", "Ana", "Julián", "Leo"])
        #expect(AgentRoster.ordered(profiles, by: []).map(\.name) == ["Ana", "Julián", "Leo", "Mateo", "Tomás"])
    }

    @Test func movingARowKeepsAgentsThisDeviceDoesNotList() {
        let shown = ["julian", "tomas", "mateo", "leo"]
        let next = AgentRoster.order(afterMoving: IndexSet(integer: 1), to: 0, in: shown, saved: ["julian", "elsewhere", "tomas"])
        #expect(next == ["tomas", "julian", "mateo", "leo", "elsewhere"])
        #expect(AgentRoster.order(afterMoving: IndexSet(integer: 0), to: 4, in: shown, saved: []) == ["tomas", "mateo", "leo", "julian"])
    }

    @Test func summariesFollowTheSavedOrder() throws {
        let profiles = [profile("j", "Julián"), profile("t", "Tomás")]
        let summaries = AgentRoster.summaries(profiles: profiles, order: ["t"], sessions: [], context: .init(tasks: []), now: now) { _ in nil }
        #expect(summaries.map(\.id) == ["t", "j"])
        #expect(summaries.allSatisfy { $0.open == 0 && $0.weekly == nil })
    }

    // MARK: What it waits on you for

    private func summary(of agent: AgentProfile, _ sessions: [Session], at date: Date? = nil,
                         threads: [String: AgentRoomThread] = [:]) -> AgentSummary {
        AgentRoster.summary(of: agent, sessions: sessions, context: SessionListFilter.Context(tasks: []), now: date ?? now,
                            usage: { _ in nil }, threads: threads)
    }

    @Test func whatAnAgentWaitsOnYouForIsAnApprovalFirstThenAReply() throws {
        let tomas = profile("tomas", "Tomás")
        // A permission request: Approve, where its card is (the session).
        let asks = summary(of: tomas, [try session("asks", agent: "tomas", activity: .permission)])
        #expect(asks.ask == AgentSummary.Ask(action: .approve, selection: "asks"))
        // A question (AskUserQuestion, a plan to accept): Reply, on that session.
        let question = summary(of: tomas, [try session("question", agent: "tomas", activity: .question)])
        #expect(question.ask == AgentSummary.Ask(action: .reply, selection: "question"))
        // Its newest unread reply: Reply, on that session.
        let unread = summary(of: tomas, [
            try session("older", agent: "tomas", activity: .unread, lastActiveMs: 1_000),
            try session("newer", agent: "tomas", activity: .unread, lastActiveMs: 2_000),
        ])
        #expect(unread.ask == AgentSummary.Ask(action: .reply, selection: "newer"))
        // Unread while it still works: nothing to answer yet.
        let busy = summary(of: tomas, [try session("busy", agent: "tomas", activity: .working, unread: true)])
        #expect(busy.ask == nil)
        #expect(busy.state == .working)
        // A request beats a newer unread reply.
        let both = summary(of: tomas, [
            try session("asks", agent: "tomas", activity: .permission, lastActiveMs: 1_000),
            try session("unread", agent: "tomas", activity: .unread, lastActiveMs: 2_000),
        ])
        #expect(both.ask == AgentSummary.Ask(action: .approve, selection: "asks"))
        // An open task alone counts on the badge but asks nothing, and the agent doesn't rise.
        let task = AgentTask(json: ["v": 1, "id": "t", "title": "t", "status": "todo", "assignee": ["kind": "user"],
                                    "threads": ["tasked"], "log": [], "createdAt": 0, "updatedAt": 0])!
        let tasked = AgentRoster.summary(of: tomas, sessions: [try session("tasked", agent: "tomas")],
                                         context: SessionListFilter.Context(tasks: [task]), now: now, usage: { _ in nil })
        #expect(tasked.needsYou == 1)
        #expect(tasked.ask == nil)
        #expect(tasked.state != .needsYou)
    }

    @Test func anUnreadReplyInItsChatOpensTheChatNotTheThread() throws {
        let tomas = profile("tomas", "Tomás")
        let chat = AgentProfile.selection(id: "tomas")
        let threads = ["t1": AgentRoomThread(selection: chat, inFlight: false)]
        // Its chat's thread is newer or older than a plain unread session: the chat answers first.
        let unread = summary(of: tomas, [
            try session("plain", agent: "tomas", activity: .unread, lastActiveMs: 3_000),
            try session("t1", agent: "tomas", activity: .unread, lastActiveMs: 2_000),
        ], threads: threads)
        #expect(unread.ask == AgentSummary.Ask(action: .reply, selection: chat))
        // Put to rest but not archived, the chat's reply still waits for you.
        let resting = summary(of: tomas, [try session("t1", agent: "tomas", active: false, activity: .unread)], threads: threads)
        #expect(resting.ask == AgentSummary.Ask(action: .reply, selection: chat))
        #expect(resting.state == .needsYou)
        let archived = summary(of: tomas, [try session("t1", agent: "tomas", active: false, archived: true, activity: .unread)],
                               threads: threads)
        #expect(archived.ask == nil)
        // A group room's thread opens the room.
        let room = AgentRoom.selection(id: "r1")
        let group = summary(of: tomas, [try session("g1", agent: "tomas", activity: .unread)],
                            threads: ["g1": AgentRoomThread(selection: room, inFlight: false)])
        #expect(group.ask == AgentSummary.Ask(action: .reply, selection: room))
        // While its daemon delivers the next message (the seat's turn is under way) the thread is
        // working, not waiting: no Reply flashes, and a thread never asks to be opened itself.
        let delivering = summary(of: tomas, [try session("t1", agent: "tomas", activity: .unread)],
                                 threads: ["t1": AgentRoomThread(selection: chat, inFlight: true)])
        #expect(delivering.ask == nil)
        #expect(delivering.state == .working)
        let working = summary(of: tomas, [try session("t1", agent: "tomas", activity: .working, unread: true)], threads: threads)
        #expect(working.ask == nil)
        #expect(working.state == .working)
    }

    @Test func agentsThatNeedYouComeFirstAndTheRestKeepTheSavedOrder() throws {
        let profiles = [profile("a", "Ana"), profile("b", "Beto"), profile("c", "Ceci"), profile("d", "Dani")]
        let sessions = [
            try session("b1", agent: "b", activity: .permission),
            try session("c1", agent: "c", activity: .working),
            try session("d1", agent: "d", activity: .unread),
        ]
        let order = ["a", "b", "c", "d"]
        let summaries = AgentRoster.summaries(profiles: profiles, order: order, sessions: sessions, context: .init(tasks: []),
                                              now: now, usage: { _ in nil })
        #expect(AgentRoster.needingYouFirst(summaries).map(\.id) == ["b", "d", "a", "c"])
        // The saved order itself is the user's: it never moves.
        #expect(AgentRoster.ordered(profiles, by: order).map(\.id) == order)
        #expect(summaries.map(\.id) == order)
    }

    /// One rule for a session's line, in the agent's card and in a chat's session card alike.
    @Test func aSessionsLineReadsItsThreadsNowElseItsFolder() throws {
        let context = SessionListFilter.Context(tasks: [])
        let memory = AgentMemory(now: [
            .init(sessionId: "busy", text: "  Fixing the login\n", updatedAt: 1),
            .init(sessionId: "asks", text: " ", updatedAt: 1),
        ])
        let busy = AgentRoster.line(of: try session("busy", agent: "tomas", activity: .working, lastActiveMs: 3_000),
                                    memory: memory, context: context, now: now)
        #expect(busy.title == "busy")
        #expect(busy.detail == "Fixing the login")
        #expect(busy.doing)
        #expect(busy.state == .working)
        #expect(busy.lastActivity == Date(timeIntervalSince1970: 3))
        // Without word from its thread (or a blank one): where it works, never the agent's name again.
        let asks = AgentRoster.line(of: try session("asks", agent: "tomas", activity: .question), memory: memory, context: context, now: now)
        #expect(asks.detail == "app")
        #expect(!asks.doing)
        #expect(asks.state == .needsYou)
        let quiet = AgentRoster.line(of: try session("quiet", agent: "tomas"), memory: nil, context: context, now: now)
        #expect(quiet.detail == "app")
        #expect(quiet.state == .idle)
        #expect(quiet.lastActivity == Date(timeIntervalSince1970: 1))
        let unread = AgentRoster.line(of: try session("unread", agent: "tomas", activity: .unread), memory: nil, context: context, now: now)
        #expect(unread.state == .needsYou)
    }

    @Test func itsCircleShowsNeedsYouThenWorkingThenFailedThenAsleep() throws {
        let tomas = profile("tomas", "Tomás")
        let needsYou = summary(of: tomas, [
            try session("asks", agent: "tomas", activity: .permission),
            try session("busy", agent: "tomas", activity: .working),
        ])
        #expect(needsYou.state == .needsYou)
        let working = summary(of: tomas, [
            try session("busy", agent: "tomas", activity: .working, lastActiveMs: 1_000),
            try session("broke", agent: "tomas", activity: .failed, lastActiveMs: 2_000),
        ])
        #expect(working.state == .working)
        // Its newest session's turn failed.
        #expect(summary(of: tomas, [try session("broke", agent: "tomas", activity: .failed)]).state == .failed)
        let recovered = summary(of: tomas, [
            try session("broke", agent: "tomas", activity: .failed, lastActiveMs: 1_000),
            try session("fine", agent: "tomas", lastActiveMs: 2_000),
        ])
        #expect(recovered.state == .idle)
        // Asleep: nothing open, or a day without news.
        #expect(summary(of: tomas, []).state == .asleep)
        let quiet = [try session("quiet", agent: "tomas", lastActiveMs: 1_000)]
        #expect(summary(of: tomas, quiet, at: Date(timeIntervalSince1970: 1 + 23 * 3600)).state == .idle)
        #expect(summary(of: tomas, quiet, at: Date(timeIntervalSince1970: 1 + 25 * 3600)).state == .asleep)
        // Something waiting on you is never asleep, however old.
        let waiting = [try session("old", agent: "tomas", activity: .unread, lastActiveMs: 1_000)]
        #expect(summary(of: tomas, waiting, at: Date(timeIntervalSince1970: 1 + 25 * 3600)).state == .needsYou)
    }
}

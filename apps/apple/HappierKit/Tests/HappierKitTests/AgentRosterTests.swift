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

    private enum Activity { case idle, working, permission, unread }

    private func session(_ id: String, agent: String?, flavor: String = "claude", active: Bool = true, archived: Bool = false,
                         activity: Activity = .idle, lastActiveMs: Double = 1_000) throws -> Session {
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
        case .unread: row["unreadSince"] = 7
        }
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
}

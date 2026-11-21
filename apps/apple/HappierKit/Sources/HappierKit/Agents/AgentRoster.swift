import Foundation

/// The agents at the top of the session list: each of your agents with its open sessions, how
/// many work or need you, what it waits on you for and where it stands, and the weekly usage of
/// the account it runs on.
public struct AgentSummary: Identifiable, Equatable, Sendable {
    /// Where one of the agent's open sessions stands, as its card lists it.
    public enum SessionState: Equatable, Sendable { case needsYou, working, idle }

    /// What the agent waits on you for, and where you answer it.
    public struct Ask: Equatable, Sendable {
        public enum Action: Equatable, Sendable { case approve, reply }

        public let action: Action
        /// What opens it: a session's id, the agent's chat (`AgentProfile.selection`) or a room (`AgentRoom.selection`).
        public let selection: String

        public init(action: Action, selection: String) {
            self.action = action
            self.selection = selection
        }
    }

    /// Where the agent stands, as its circle shows it: it waits on you (`ask`), works (a session,
    /// or a room's turn under way), its newest session's turn failed, nothing for a day (or nothing
    /// open), or idle otherwise.
    public enum State: Equatable, Sendable { case needsYou, working, failed, idle, asleep }

    public let profile: AgentProfile
    /// Its open sessions (running, not archived), most recently active first.
    public let sessions: [Session]
    public let working: Int
    /// Open sessions that need you, by the list filter's own rule (`SessionListFilter.Context.needsAttention`):
    /// the circle's count. An open task counts here but asks nothing (`ask`).
    public let needsYou: Int
    /// The weekly limit of the agent's own account, from the newest reading of its sessions.
    public let weekly: ProviderUsage.Meter?

    /// The most recently active of its sessions that is working, named in its row.
    public let latestWorking: Session?
    /// What it waits on you for (`AgentRoster.ask`); nil when nothing does.
    public let ask: Ask?
    public let state: State

    public var id: String { profile.id }
    public var open: Int { sessions.count }
    /// When its most recently active session last did something; nil without open sessions.
    public var lastActivity: Date? { sessions.first?.sortDate }
}

/// A member's thread in a room (its seat's session), as the circles read it.
public struct AgentRoomThread: Equatable, Sendable {
    /// Where its replies are read: the agent's chat (`AgentProfile.selection`) or the group room (`AgentRoom.selection`).
    public let selection: String
    /// The member's turn for the room is under way (its seat's `inFlight`): delivered, so working.
    public let inFlight: Bool

    public init(selection: String, inFlight: Bool) {
        self.selection = selection
        self.inFlight = inFlight
    }
}

public enum AgentRoster {
    /// The agent's open sessions: working as it (`agentIdentityV1`), running and not archived.
    public static func openSessions(of profile: AgentProfile, in sessions: some Sequence<Session>) -> [Session] {
        sessions
            .filter { $0.active && $0.archivedAt == nil && $0.agentIdentity?.id == profile.id }
            .sorted { $0.sortDate > $1.sortDate }
    }

    /// One summary per profile, in the saved order. `usage` is the reading shown for a session
    /// (`HappierStore.usage(for:)`); `now` is the store's presence date.
    public static func summaries(profiles: [AgentProfile], order: [String], sessions: [Session],
                                 context: SessionListFilter.Context, now: Date,
                                 usage: (Session) -> ProviderUsage?, threads: [String: AgentRoomThread] = [:]) -> [AgentSummary] {
        ordered(profiles, by: order).map { summary(of: $0, sessions: sessions, context: context, now: now, usage: usage, threads: threads) }
    }

    /// `threads` are the rooms' threads by session id (`HappierStore.roomThreads`): a reply there is
    /// read, and answered, in its room.
    public static func summary(of profile: AgentProfile, sessions: [Session], context: SessionListFilter.Context, now: Date,
                               usage: (Session) -> ProviderUsage?, threads: [String: AgentRoomThread] = [:]) -> AgentSummary {
        let open = openSessions(of: profile, in: sessions)
        // Its rooms' threads, put to rest or not (their replies still wait to be read), newest first.
        let threadSessions = sessions
            .filter { $0.archivedAt == nil && $0.agentIdentity?.id == profile.id && threads[$0.id] != nil }
            .sorted { $0.sortDate > $1.sortDate }
        // Sessions come most recently active first.
        let latestWorking = open.first { $0.status(at: now) == .working }
        let ask = ask(open: open, threadSessions: threadSessions, now: now, threads: threads)
        let state: AgentSummary.State
        if ask != nil {
            state = .needsYou
        } else if latestWorking != nil || threadSessions.contains(where: { threads[$0.id]?.inFlight == true }) {
            state = .working
        } else if open.first?.status(at: now) == .failed {
            state = .failed
        } else if let last = open.first?.sortDate, now.timeIntervalSince(last) <= 24 * 3600 {
            state = .idle
        } else {
            state = .asleep
        }
        return AgentSummary(
            profile: profile, sessions: open,
            working: open.count { $0.status(at: now) == .working },
            needsYou: open.count { context.needsAttention($0, now: now) },
            weekly: weeklyUsage(of: profile, sessions: sessions, usage: usage),
            latestWorking: latestWorking, ask: ask, state: state)
    }

    /// What the agent waits on you for: a request to approve, on its session; else a question
    /// (AskUserQuestion, a plan), on its session, where its card is; else an unread reply in one of
    /// its rooms, in the room (its chat, or the group room), where it is read; else its newest
    /// unread session. What is unread while still working asks nothing yet, and a room's thread is
    /// working from the moment its turn is delivered (the seat's `inFlight`). An open task alone
    /// asks nothing: it counts in `needsYou` only.
    private static func ask(open: [Session], threadSessions: [Session], now: Date,
                            threads: [String: AgentRoomThread]) -> AgentSummary.Ask? {
        if let request = open.first(where: { $0.status(at: now) == .permissionRequired }) {
            return AgentSummary.Ask(action: .approve, selection: request.id)
        }
        if let question = open.first(where: { $0.status(at: now) == .actionRequired }) {
            return AgentSummary.Ask(action: .reply, selection: question.id)
        }
        let unreadAndDone = { (session: Session) in session.unreadSince != nil && session.status(at: now) != .working }
        for session in threadSessions where unreadAndDone(session) {
            guard let thread = threads[session.id], !thread.inFlight else { continue }
            return AgentSummary.Ask(action: .reply, selection: thread.selection)
        }
        if let unread = open.first(where: { threads[$0.id] == nil && unreadAndDone($0) }) {
            return AgentSummary.Ask(action: .reply, selection: unread.id)
        }
        return nil
    }

    /// The agents that wait on you first, the rest after; each group keeps the order it came in
    /// (the saved one). The saved order itself never changes.
    public static func needingYouFirst(_ summaries: [AgentSummary]) -> [AgentSummary] {
        summaries.filter { $0.ask != nil } + summaries.filter { $0.ask == nil }
    }

    /// The one session to read the agent's usage from when none is shown yet: its most recently
    /// active session that carries usage records, on its own provider. Nil when there's none.
    public static func sessionToReadUsage(of profile: AgentProfile, sessions: [Session]) -> Session? {
        sessions
            .filter { $0.archivedAt == nil && $0.agentIdentity?.id == profile.id && $0.agentId == profile.providerId
                && !ProviderUsage.recordIds(in: $0.metadata).isEmpty }
            .max { $0.sortDate < $1.sortDate }
    }

    /// One of an agent's sessions as a row or a card names it (the agent's card, a session card in
    /// a chat): the view differs, this is what it says.
    public struct SessionLine: Equatable, Sendable {
        public let title: String
        /// What its thread last said it is doing (the memory's `now`), else where it works
        /// (`Session.listPlace`: the agent is named elsewhere). Empty when neither is known.
        public let detail: String
        /// `detail` is the thread's own words, not the place.
        public let doing: Bool
        public let state: AgentSummary.SessionState
        /// When it last did something, shown while it is idle.
        public let lastActivity: Date
    }

    /// `memory` is the memory of the agent the session works as (`HappierStore.agentMemories`), if loaded.
    public static func line(of session: Session, memory: AgentMemory?, context: SessionListFilter.Context, now: Date) -> SessionLine {
        let doing = memory?.now.first { $0.sessionId == session.id }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        return SessionLine(title: session.title, detail: doing ?? session.listPlace, doing: doing != nil,
                           state: state(of: session, context: context, now: now), lastActivity: session.sortDate)
    }

    /// A request or question first, then work in progress, then anything else the list filter
    /// counts as needing you (unread, an open task); otherwise idle.
    public static func state(of session: Session, context: SessionListFilter.Context, now: Date) -> AgentSummary.SessionState {
        switch session.status(at: now) {
        case .permissionRequired, .actionRequired: return .needsYou
        case .working: return .working
        default: return context.needsAttention(session, now: now) ? .needsYou : .idle
        }
    }

    /// The weekly limit of the agent's account: the newest reading that carries one among the
    /// agent's own sessions (they ran on its account), from its provider only.
    public static func weeklyUsage(of profile: AgentProfile, sessions: some Sequence<Session>,
                                   usage: (Session) -> ProviderUsage?) -> ProviderUsage.Meter? {
        var newest: (meter: ProviderUsage.Meter, fetchedAt: Date)?
        for session in sessions where session.archivedAt == nil && session.agentIdentity?.id == profile.id {
            // A session switched to another engine read that provider's account, not this agent's.
            guard let reading = usage(session), (reading.providerId ?? session.agentId) == profile.providerId,
                  let weekly = reading.weeklyLimit(modelId: profile.modelId) else { continue }
            let fetchedAt = reading.fetchedAt ?? .distantPast
            if newest.map({ fetchedAt > $0.fetchedAt }) ?? true { newest = (weekly, fetchedAt) }
        }
        return newest?.meter
    }

    /// Profiles in the saved order; any it doesn't name follow, by name.
    public static func ordered(_ profiles: [AgentProfile], by order: [String]) -> [AgentProfile] {
        var rank: [String: Int] = [:]
        for (index, id) in order.enumerated() where rank[id] == nil { rank[id] = index }
        return profiles.sorted { a, b in
            switch (rank[a.id], rank[b.id]) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    /// The order to save after moving rows of `shown` (ids as listed): the new list, then any
    /// saved id this device doesn't list (an agent another device knows), so nothing is lost.
    public static func order(afterMoving offsets: IndexSet, to destination: Int, in shown: [String], saved: [String]) -> [String] {
        let moving = offsets.filter(shown.indices.contains).map { shown[$0] }
        var rest = shown.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let insertAt = destination - offsets.count { $0 < destination }
        rest.insert(contentsOf: moving, at: min(max(insertAt, 0), rest.count))
        let listed = Set(rest)
        return rest + saved.filter { !listed.contains($0) }
    }
}

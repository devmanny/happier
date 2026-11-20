import Foundation

/// The agents at the top of the session list: each of your agents with its open sessions, how
/// many work or need you, and the weekly usage of the account it runs on.
public struct AgentSummary: Identifiable, Equatable, Sendable {
    /// Where one of the agent's open sessions stands, as its card lists it.
    public enum SessionState: Equatable, Sendable { case needsYou, working, idle }

    public let profile: AgentProfile
    /// Its open sessions (running, not archived), most recently active first.
    public let sessions: [Session]
    public let working: Int
    /// Open sessions that need you, by the list filter's own rule (`SessionListFilter.Context.needsAttention`).
    public let needsYou: Int
    /// The weekly limit of the agent's own account, from the newest reading of its sessions.
    public let weekly: ProviderUsage.Meter?

    /// The most recently active of its sessions that is working, named in its row.
    public let latestWorking: Session?

    public var id: String { profile.id }
    public var open: Int { sessions.count }
    /// When its most recently active session last did something; nil without open sessions.
    public var lastActivity: Date? { sessions.first?.sortDate }
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
                                 usage: (Session) -> ProviderUsage?) -> [AgentSummary] {
        ordered(profiles, by: order).map { summary(of: $0, sessions: sessions, context: context, now: now, usage: usage) }
    }

    public static func summary(of profile: AgentProfile, sessions: [Session], context: SessionListFilter.Context, now: Date,
                               usage: (Session) -> ProviderUsage?) -> AgentSummary {
        let open = openSessions(of: profile, in: sessions)
        return AgentSummary(
            profile: profile, sessions: open,
            working: open.count { $0.status(at: now) == .working },
            needsYou: open.count { context.needsAttention($0, now: now) },
            weekly: weeklyUsage(of: profile, sessions: sessions, usage: usage),
            // Sessions come most recently active first.
            latestWorking: open.first { $0.status(at: now) == .working })
    }

    /// The one session to read the agent's usage from when none is shown yet: its most recently
    /// active session that carries usage records, on its own provider. Nil when there's none.
    public static func sessionToReadUsage(of profile: AgentProfile, sessions: [Session]) -> Session? {
        sessions
            .filter { $0.archivedAt == nil && $0.agentIdentity?.id == profile.id && $0.agentId == profile.providerId
                && !ProviderUsage.recordIds(in: $0.metadata).isEmpty }
            .max { $0.sortDate < $1.sortDate }
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

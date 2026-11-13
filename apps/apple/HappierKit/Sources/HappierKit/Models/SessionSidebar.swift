import Foundation

/// How the sessions sidebar groups conversations: pinned ones first, then the running ones, then
/// the ones not running that were used lately, and the older ones in two groups that stay
/// collapsed until asked for: resting (put to rest by the idle cleaner, `Session.isResting`) and
/// stopped (everything else). Archived sessions are not part of the list at all; they are fetched
/// only when browsed or searched.
public enum SessionSidebar {
    public struct Groups {
        public let pinned: [SessionTreeNode<Session>]
        public let active: [SessionTreeNode<Session>]
        /// Not running, resting or stopped, with activity since `recentSince`; empty without it.
        public let recent: [SessionTreeNode<Session>]
        public let resting: [SessionTreeNode<Session>]
        public let stopped: [SessionTreeNode<Session>]
    }

    /// Sessions started from inside another one stay under it; a family with any running member
    /// counts as running, and one that isn't goes by its top session, resting or stopped, with its
    /// sub-sessions beneath it whatever their own state (each row shows its own). Pinned
    /// conversations are always top-level rows. Every section is ordered by each family's latest
    /// activity, so a message in a child brings its whole family up.
    /// `shows` is the list's filter; a pinned conversation is listed whatever it says, since
    /// pinning is explicit (a task session you pinned stays in Pinned).
    /// With `recentSince`, a family not running whose latest activity is that recent goes to
    /// `recent` instead of its group; without it, `resting` and `stopped` hold them all.
    public static func groups(_ sessions: [Session], pinned: [String], date: (Session) -> Date = \.sortDate,
                              recentSince: Date? = nil, shows: (Session) -> Bool = { _ in true }) -> Groups {
        let pinnedSet = Set(pinned)
        let sessions = sessions.filter { pinnedSet.contains($0.id) || shows($0) }
        let roots = SessionTree.build(sessions, parent: { pinnedSet.contains($0.id) ? nil : $0.parentSessionId }, date: date)
        let unpinned = roots.filter { !pinnedSet.contains($0.id) }
        let notRunning = unpinned.filter { !isRunning($0) }
        let recent = recentSince.map { since in notRunning.filter { latest($0, date: date) >= since } } ?? []
        let recentIds = Set(recent.map(\.id))
        let older = notRunning.filter { !recentIds.contains($0.id) }
        return Groups(pinned: roots.filter { pinnedSet.contains($0.id) }, active: unpinned.filter(isRunning), recent: recent,
                      resting: older.filter(\.item.isResting), stopped: older.filter { !$0.item.isResting })
    }

    private static func latest(_ node: SessionTreeNode<Session>, date: (Session) -> Date) -> Date {
        (node.children ?? []).reduce(date(node.item)) { max($0, latest($1, date: date)) }
    }

    private static func isRunning(_ node: SessionTreeNode<Session>) -> Bool {
        node.item.active || (node.children ?? []).contains(where: isRunning)
    }
}

extension Session {
    /// The sidebar search: title or folder.
    public func matches(_ query: String) -> Bool {
        title.localizedCaseInsensitiveContains(query) || (displayPath ?? "").localizedCaseInsensitiveContains(query)
    }
}

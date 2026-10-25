import Foundation

/// How the sessions sidebar groups conversations: pinned ones first, then the running ones, and the
/// stopped ones in a group that stays collapsed until asked for. Archived sessions are not part of
/// the list at all; they are fetched only when browsed or searched.
public enum SessionSidebar {
    public struct Groups {
        public let pinned: [SessionTreeNode<Session>]
        public let active: [SessionTreeNode<Session>]
        public let inactive: [SessionTreeNode<Session>]
    }

    /// Sessions started from inside another one stay under it; a family with any running member
    /// counts as running. Pinned conversations are always top-level rows. Every section is ordered
    /// by each family's latest activity, so a message in a child brings its whole family up.
    public static func groups(_ sessions: [Session], pinned: [String], date: (Session) -> Date = \.sortDate) -> Groups {
        let pinnedSet = Set(pinned)
        let roots = SessionTree.build(sessions, parent: { pinnedSet.contains($0.id) ? nil : $0.parentSessionId }, date: date)
        let unpinned = roots.filter { !pinnedSet.contains($0.id) }
        return Groups(pinned: roots.filter { pinnedSet.contains($0.id) },
                      active: unpinned.filter(isRunning), inactive: unpinned.filter { !isRunning($0) })
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

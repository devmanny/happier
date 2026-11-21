import Foundation

/// How the sessions sidebar groups conversations: pinned ones first, then the running ones, then
/// the ones not running that were used lately, and the older ones in two groups that stay
/// collapsed until asked for: resting (put to rest by the idle cleaner, `Session.isResting`) and
/// stopped (everything else). Archived sessions are not part of the list at all; they are fetched
/// only when browsed or searched.
public enum SessionSidebar {
    public struct Groups {
        public let pinned: [SessionTreeNode<Session>]
        /// The user's groups in their order, each with its sessions whatever their state; empty ones too.
        public let grouped: [GroupSection]
        public let active: [SessionTreeNode<Session>]
        /// Not running, resting or stopped, with activity since `recentSince`; empty without it.
        public let recent: [SessionTreeNode<Session>]
        public let resting: [SessionTreeNode<Session>]
        public let stopped: [SessionTreeNode<Session>]
    }

    /// A group of the user's and the sessions in it.
    public struct GroupSection: Identifiable {
        public let group: SessionGroup
        public let nodes: [SessionTreeNode<Session>]
        public var id: String { group.id }
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
    /// A session in one of `groups` (`groupIds`) is listed in its group instead, whatever its
    /// state, unless pinned; a sub-session goes with its parent unless put in another group.
    public static func groups(_ sessions: [Session], pinned: [String], groups: [SessionGroup] = [], groupIds: [String: String] = [:],
                              date: (Session) -> Date = \.sortDate, recentSince: Date? = nil,
                              shows: (Session) -> Bool = { _ in true }) -> Groups {
        let pinnedSet = Set(pinned)
        let known = Set(groups.map(\.id))
        let groupIds = groupIds.filter { known.contains($0.value) }
        let sessions = sessions.filter { pinnedSet.contains($0.id) || shows($0) }
        let roots = SessionTree.build(sessions, parent: { session in
            if pinnedSet.contains(session.id) { return nil }
            if let group = groupIds[session.id], group != session.parentSessionId.flatMap({ groupIds[$0] }) { return nil }
            return session.parentSessionId
        }, date: date)
        let unpinned = roots.filter { !pinnedSet.contains($0.id) }
        let byGroup = Dictionary(grouping: unpinned.filter { groupIds[$0.id] != nil }) { groupIds[$0.id]! }
        let ungrouped = unpinned.filter { groupIds[$0.id] == nil }
        let notRunning = ungrouped.filter { !isRunning($0) }
        let recent = recentSince.map { since in notRunning.filter { latest($0, date: date) >= since } } ?? []
        let recentIds = Set(recent.map(\.id))
        let older = notRunning.filter { !recentIds.contains($0.id) }
        return Groups(pinned: roots.filter { pinnedSet.contains($0.id) },
                      grouped: groups.map { GroupSection(group: $0, nodes: byGroup[$0.id] ?? []) },
                      active: ungrouped.filter(isRunning), recent: recent,
                      resting: older.filter(\.item.isResting), stopped: older.filter { !$0.item.isResting })
    }

    /// The sessions of one folder (`SessionSidebar.folders`).
    public struct FolderSection: Identifiable {
        /// The machine and the folder's path.
        public let id: String
        /// The folder's name; its path where another listed folder has the same name, and the
        /// computer's name where that path is listed on more than one.
        public let title: String
        public let nodes: [SessionTreeNode<Session>]
    }

    /// The list by folder: families under the folder their top session works in (on its machine),
    /// folders by their latest activity, the ones without a folder last.
    public static func folders(_ nodes: [SessionTreeNode<Session>], date: (Session) -> Date = \.sortDate) -> [FolderSection] {
        func key(_ session: Session) -> String {
            guard let path = session.path, !path.isEmpty else { return "" }
            return (session.machineId ?? "") + "\u{1F}" + AccountSettings.folderKey(path)
        }
        var order: [String] = []
        var byKey: [String: [SessionTreeNode<Session>]] = [:]
        for node in nodes {
            let key = key(node.item)
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(node)
        }
        let sections = order.map { key -> (key: String, nodes: [SessionTreeNode<Session>], latest: Date) in
            let nodes = byKey[key]!.map { ($0, latest($0, date: date)) }.sorted { $0.1 > $1.1 }
            return (key, nodes.map(\.0), nodes.first?.1 ?? .distantPast)
        }
        .sorted { a, b in
            if a.key.isEmpty != b.key.isEmpty { return b.key.isEmpty }
            return a.latest > b.latest
        }
        // Names first, then the path where a name repeats, then the computer where a path repeats.
        let names = sections.map { $0.key.isEmpty ? String(localized: "No Folder") : ($0.nodes[0].item.folderName ?? "") }
        let paths = sections.map { $0.nodes[0].item.displayPath ?? "" }
        let titles = sections.indices.map { index -> String in
            guard !sections[index].key.isEmpty, names.indices.contains(where: { $0 != index && names[$0] == names[index] }) else { return names[index] }
            let path = paths[index]
            guard paths.indices.contains(where: { $0 != index && names[$0] == names[index] && paths[$0] == path }),
                  let host = sections[index].nodes[0].item.host else { return path }
            return "\(path) · \(host)"
        }
        return sections.indices.map { FolderSection(id: sections[$0].key, title: titles[$0], nodes: sections[$0].nodes) }
    }

    /// A flat list by folder (a filter's results).
    public static func folders(_ sessions: [Session], date: (Session) -> Date = \.sortDate) -> [FolderSection] {
        folders(sessions.map { SessionTreeNode(item: $0, children: nil) }, date: date)
    }

    private static func latest(_ node: SessionTreeNode<Session>, date: (Session) -> Date) -> Date {
        (node.children ?? []).reduce(date(node.item)) { max($0, latest($1, date: date)) }
    }

    private static func isRunning(_ node: SessionTreeNode<Session>) -> Bool {
        node.item.active || (node.children ?? []).contains(where: isRunning)
    }
}

/// How the list groups the sessions in view: by state (Pinned, Active, Recent…), the usual list,
/// or by the folder they work in. Kept on the device, like the filter.
public enum SessionListGrouping: String, CaseIterable, Sendable, Identifiable {
    case status, folder

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .status: String(localized: "Status")
        case .folder: String(localized: "Folder")
        }
    }
}

extension Session {
    /// The sidebar search: title, folder, or the model it runs on ("opus", "Opus 5.5", "gpt-6.1").
    public func matches(_ query: String) -> Bool {
        if title.localizedCaseInsensitiveContains(query) || (displayPath ?? "").localizedCaseInsensitiveContains(query) { return true }
        guard let model = runningModel else { return false }
        return model.word.localizedCaseInsensitiveContains(query) || RunningModel.name(for: model.id).localizedCaseInsensitiveContains(query)
    }
}

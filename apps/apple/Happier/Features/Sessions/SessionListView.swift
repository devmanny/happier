import HappierKit
import SwiftUI

/// The session list as the sidebar shows it. With dozens of sessions streaming, following every
/// message re-sorted and redrew the whole list many times a second, even behind an open chat on
/// the iPhone (a warm phone, a busy Mac); this follows the store and lets a burst settle first.
@MainActor @Observable
private final class SessionListSnapshot {
    /// Nil until the first read; the list then reads the store directly.
    private(set) var sessions: [Session]?

    func follow(_ store: HappierStore) async {
        while !Task.isCancelled {
            await withCheckedContinuation { continuation in
                let next = withObservationTracking { store.sessionList } onChange: { continuation.resume() }
                if next != sessions { sessions = next }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}

/// The conversation list. In the iPhone side drawer (`onOpen` set) it is the ChatGPT/Claude-style
/// sidebar: compact rows that keep the agent icon and the folder, Pinned and Recent sections, and
/// the account and New Session at the bottom. In the split view (Mac, iPad) it is the sidebar column.
struct SessionListView: View {
    @Environment(HappierStore.self) private var store
    @Binding var selection: String?
    /// Opens a conversation from the drawer (the split view selects through `selection` instead).
    var onOpen: ((String) -> Void)?
    @State private var query = ""
    @State private var showAccount = false
    @State private var showNotifications = false
    @State private var showTasks = false
    @Environment(\.tasksPanelAvailable) private var tasksPanelAvailable
    @Environment(NotificationInbox.self) private var inbox
    /// The bell carries a dot while notifications of sessions still listed are waiting.
    private var unseenNotifications: Bool {
        inbox.notifications.contains { notification in
            notification.sessionId.map { store.sessions[$0]?.archivedAt == nil } ?? true
        }
    }
    @State private var showRelay = false
    /// Resting, stopped and archived sessions open in their own window, at this section.
    @State private var olderSessions: OlderSessionsSection?
    /// The archive, loaded only while a search runs or the filter shows archived sessions.
    @State private var archivedSearch: ArchivedSessions?
    /// What the search finds inside messages, from the Mac that keeps the index.
    @State private var messageSearch = MessageSearchResults()
    /// The filter button's chosen filter and whether it's on, kept on this device.
    @AppStorage("happier.sessionListFilter") private var storedFilter = ""
    @State private var showFilter = false
    /// By state (the usual list) or by the folder the sessions work in, kept on this device.
    @AppStorage("happier.sessionList.grouping") private var storedGrouping = SessionListGrouping.status.rawValue
    /// The session a new group is being named for.
    @State private var groupingSession: Session?
    @State private var renamingGroup: SessionGroup?
    @State private var deletingGroup: SessionGroup?
    /// The running sessions offered to put to rest, while the user picks which.
    @State private var restChoice: SessionRest.Candidates?
    /// Sessions whose sub-sessions are unfolded.
    @State private var expanded: Set<String> = []
    /// A session dropped on another, waiting for what to do with the two.
    @State private var combining: SessionCombine?
    /// The session being renamed, and the name typed for it.
    @State private var renaming: Session?
    /// The session to put inside another one, picked from a list ("Move Into…").
    @State private var movingInto: Session?
    /// A session started from a row's folder, with its machine preserved in the assistant.
    @State private var newSessionDraft: NewSessionDraft?
    /// A session started from an agent's card, with that agent chosen.
    @State private var newSessionAgent: AgentProfile?
    /// The group whose "Reorder Groups…" is open: it and the groups beside it, to drag into place.
    @State private var reorderingGroups: SessionGroup?
    /// The agents' Edit: their rows show drag handles.
    @State private var editingAgents = false
    /// The row a dragged session is over.
    @State private var dropTarget: String?
    #if os(macOS)
    /// The session a dragged file is held over, opened after a moment (spring-loading).
    @State private var springTarget: String?
    #endif
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    /// The conversation just closed (going back from it to the list): its row lights up and fades
    /// back over two seconds, so you see which one you were in.
    @State private var justClosed: String?
    @State private var justClosedGlow = false
    #if os(iOS)
    private static let rowBackground = Color(uiColor: .secondarySystemGroupedBackground)
    #else
    private static let rowBackground = Color.clear
    #endif

    /// The sorted list, refreshed at most twice a second instead of on every message.
    @State private var listed = SessionListSnapshot()

    private var sessions: [Session] {
        let all = listed.sessions ?? store.sessionList
        guard !query.isEmpty else { return all }
        return SessionPins.pinnedFirst(all.filter { $0.matches(query) }, pinned: store.pinnedSessionIds, id: \.id)
    }

    private var archivedMatches: [Session] {
        archivedSearch?.items.filter { $0.matches(query) && !store.deletedSessionIds.contains($0.id) } ?? []
    }

    private var filterChoice: SessionListFilterChoice { SessionListFilterChoice(stored: storedFilter) }
    private var grouping: SessionListGrouping { SessionListGrouping(rawValue: storedGrouping) ?? .status }

    private func changeGrouping(_ next: SessionListGrouping) {
        guard next != grouping else { return }
        AppHaptics.selection()
        withAnimation(.smooth(duration: 0.2)) { storedGrouping = next.rawValue }
    }
    private var filter: SessionListFilter { filterChoice.applied }

    private func changeFilter(_ change: (inout SessionListFilterChoice) -> Void) {
        var next = filterChoice
        change(&next)
        withAnimation(.smooth(duration: 0.2)) { storedFilter = next.stored }
    }

    /// A tap on the filter button: the chosen filter on or off, or the filter itself when none is chosen.
    private func switchFilter() {
        var next = filterChoice
        guard next.toggle() else {
            showFilter = true
            return
        }
        AppHaptics.selection()
        withAnimation(.smooth(duration: 0.2)) { storedFilter = next.stored }
    }

    private var filterContext: SessionListFilter.Context { store.taskContext }

    /// The list as the filter leaves it, the archive included when the filter asks for it.
    private var filteredSessions: [Session] {
        let filter = filter, context = filterContext
        var all = sessions
        if filter.includesArchived {
            let known = Set(all.map(\.id))
            all += (archivedSearch?.items ?? []).filter { !known.contains($0.id) && !store.deletedSessionIds.contains($0.id) }
        }
        return all.filter { filter.includes($0, context: context) }
    }

    /// The archive is fetched for a search, or for a filter that shows it.
    private var needsArchive: Bool { !query.isEmpty || filter.includesArchived }

    private var isDrawer: Bool { onOpen != nil }

    private func openArchived(_ session: Session) {
        store.openArchived(session)
        onOpen?(session.id)
    }

    /// A session picked in the older-sessions window.
    private func openOlder(_ session: Session) {
        if session.archivedAt != nil {
            openArchived(session)
        } else {
            open(session.id)
        }
    }

    /// Opens the conversation at the message a search found (archived or not yet listed ones load).
    private func openMessage(_ hit: MessageSearch.Hit) {
        Task {
            await store.openMessage(sessionId: hit.sessionId, seq: hit.seq)
            if store.sessions[hit.sessionId] != nil { open(hit.sessionId) }
        }
    }

    /// Opens a listed session: from the drawer, or by selecting it beside the conversation.
    private func open(_ sessionId: String) {
        if let onOpen { onOpen(sessionId) } else { selection = sessionId }
    }

    /// A session row; sessions started from inside it unfold beneath with their own button, so
    /// unfolding never opens the session (the row itself is a button in the drawer).
    @ViewBuilder
    private func row(_ session: Session, tree: TreeRow? = nil) -> some View {
        let depth = tree?.depth ?? 0
        let childCount = tree?.childCount ?? 0
        let indent = Self.drawerIndent
        // The same compact row everywhere (iPhone drawer, iPad and Mac sidebar).
        let content = HStack(spacing: 6) {
            if let onOpen {
                Button {
                    AppHaptics.selection()
                    onOpen(session.id)
                } label: {
                    SessionRow(session: session).equatable()
                        .contentShape(Rectangle())
                }
                // The row style of the list itself: it highlights the whole row on touch.
                .buttonStyle(.plain)
            } else {
                SessionRow(session: session).equatable()
            }
            if childCount > 0 { subSessionsButton(session.id, count: childCount, needsYou: tree?.hidesNeedsYou == true) }
        }
        .sessionListRow(drawer: isDrawer, indent: CGFloat(depth) * indent)
        .background(alignment: .leading) {
            if let tree { TreeLines(tree: tree, indent: Self.drawerIndent, radius: Self.drawerAvatar / 2) }
        }
        .overlay {
            if dropTarget == session.id { RowDropHighlight() }
        }
        #if os(iOS)
        // Drop a session on another to nest it there or group the two. Not on the Mac, where
        // draggable sidebar rows locked the sidebar against clicks and scrolling: there it is
        // "Move Into…" in the row's menu.
        .dropDestination(for: String.self) { items, _ in
            drop(items, on: session)
        } isTargeted: { over in
            withAnimation(.smooth(duration: 0.15)) {
                if over { dropTarget = session.id } else if dropTarget == session.id { dropTarget = nil }
            }
        }
        #else
        // Spring-loading: holding a dragged file over a session opens it, so the file can be
        // dropped into that conversation. The row itself never takes the drop.
        .onDrop(of: [.fileURL, .image], isTargeted: Binding(
            get: { springTarget == session.id },
            set: { over in
                if over { springTarget = session.id } else if springTarget == session.id { springTarget = nil }
            })) { _ in false }
        #endif
        if onOpen != nil {
            content
                .listRowBackground(selection == session.id ? DrawerRowHighlight().fill(Color.primary.opacity(0.1)) : nil)
                .rowActions(session, store: store, openInWindow: openInWindow(session), rename: { startRenaming(session) }, moveInto: { movingInto = session }, newSession: { newSessionDraft = NewSessionDraft(inFolderOf: session) },
                            newGroup: { groupingSession = session })
                #if os(iOS)
                .modifier(SessionRowDrag(session: session))
                #endif
        } else {
            content
                // The row's own background with the tint over it, so the list keeps its shape (the
                // section's rounded corners) while the glow fades.
                .listRowBackground(justClosed == session.id
                    ? Self.rowBackground.overlay(Color.userBubble.opacity(justClosedGlow ? 0.2 : 0))
                    : nil)
                .tag(session.id)
                .rowActions(session, store: store, openInWindow: openInWindow(session), rename: { startRenaming(session) }, moveInto: { movingInto = session }, newSession: { newSessionDraft = NewSessionDraft(inFolderOf: session) },
                            newGroup: { groupingSession = session })
                #if os(iOS)
                .modifier(SessionRowDrag(session: session))
                #endif
        }
    }

    /// A session dropped on `target`: straight inside when `target` already holds sessions,
    /// otherwise ask whether to nest it there or group the two under a new session.
    private func drop(_ items: [String], on target: Session) -> Bool {
        dropTarget = nil
        guard let id = items.lazy.compactMap(SessionDrag.sessionId).first, let dragged = store.sessions[id] else { return false }
        let accepted = combine(dragged, into: target)
        if accepted { AppHaptics.confirm() }
        return accepted
    }

    /// Puts `session` inside `target`: straight in when `target` already holds sessions, otherwise
    /// after asking whether to nest it there or group the two under a new session.
    @discardableResult
    private func combine(_ session: Session, into target: Session) -> Bool {
        guard session.id != target.id, store.canNest(session.id, under: target.id) else { return false }
        if store.hasNestedSessions(target.id) {
            Task { await store.nest(session.id, under: target.id) }
            withAnimation(.smooth(duration: 0.2)) { _ = expanded.insert(target.id) }
        } else {
            // Asked once the drop has finished: a dialog shown while the system is still
            // completing the drag can leave the list stuck.
            let request = SessionCombine(dragged: session, target: target)
            Task { @MainActor in
                await Task.yield()
                combining = request
            }
        }
        return true
    }

    /// "Open in New Window", where windows can be opened (Mac, iPad).
    private func openInWindow(_ session: Session) -> (() -> Void)? {
        guard supportsMultipleWindows else { return nil }
        return { openWindow(id: SessionWindow.id, value: session.id) }
    }

    private func startRenaming(_ session: Session) {
        renaming = session
    }

    /// "2 ›": how many sessions it started; tap to unfold them.
    private func subSessionsButton(_ id: String, count: Int, needsYou: Bool) -> some View {
        let open = expanded.contains(id)
        return Button {
            AppHaptics.selection()
            withAnimation(.smooth(duration: 0.2)) {
                if open { expanded.remove(id) } else { expanded.insert(id) }
            }
        } label: {
            HStack(spacing: 3) {
                Text(count, format: .number).monospacedDigit()
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .glassEffect(.regular.interactive(), in: Capsule())
            .contentShape(Capsule())
            .overlay(alignment: .topLeading) {
                // The unread dot of a row, for what needs you inside the folded branch.
                if needsYou {
                    Circle()
                        .fill(Color.userBubble)
                        .frame(width: 8, height: 8)
                        .background(Circle().fill(.background).padding(-1.5))
                        .offset(x: -1, y: -1)
                }
            }
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(open ? Text("Hide sub-sessions")
                            : needsYou ? Text("Show \(count) sub-sessions, some need you") : Text("Show \(count) sub-sessions"))
    }

    static let drawerIndent: CGFloat = 22
    /// Hairlines just off the background: they order the list without drawing the eye.
    static let separatorTint = Color.primary.opacity(0.08)
    static let drawerAvatar: CGFloat = 24
    /// The gap between a row's avatar and its text.
    static let avatarGap: CGFloat = 10

    /// A row's content insets: in the drawer, and in the sidebar (where the list adds its own margins).
    static func rowInsets(drawer: Bool) -> EdgeInsets {
        drawer ? EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 12) : EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
    }

    struct TreeRow: Identifiable {
        let session: Session
        let depth: Int
        let childCount: Int
        /// The last of its siblings: its line from the parent ends here.
        let isLast: Bool
        /// Per ancestor level, whether that branch carries on below this row.
        let trail: [Bool]
        /// Its own sub-sessions are unfolded beneath it.
        let isOpen: Bool
        /// Folded, and something in its branch needs you: its button carries the dot.
        var hidesNeedsYou = false
        var id: String { session.id }
    }

    /// The tree as rows: each session, then (when unfolded) the sessions it started, indented.
    private func treeRows(_ nodes: [SessionTreeNode<Session>], depth: Int = 0, trail: [Bool] = []) -> [TreeRow] {
        let context = store.taskContext, now = store.presenceDate()
        return nodes.enumerated().flatMap { index, node -> [TreeRow] in
            let children = node.children ?? []
            let isLast = index == nodes.count - 1
            let isOpen = expanded.contains(node.id) && !children.isEmpty
            // Counted in the section's title whether folded or not, so a folded branch shows it.
            let hidden = !isOpen && !children.isEmpty
                && SessionSidebar.activity(of: children, context: context, now: now).needingYou > 0
            let own = TreeRow(session: node.item, depth: depth, childCount: children.count, isLast: isLast, trail: trail,
                              isOpen: isOpen, hidesNeedsYou: hidden)
            return isOpen ? [own] + treeRows(children, depth: depth + 1, trail: trail + [!isLast]) : [own]
        }
    }

    private func outline(_ nodes: [SessionTreeNode<Session>]) -> some View {
        ForEach(treeRows(nodes)) { tree in row(tree.session, tree: tree) }
    }

    /// How long a session that isn't running stays in the list itself before it waits in its group.
    private static let recentWindow: TimeInterval = 48 * 3600

    /// The usual list (the default filter, which leaves out the sessions tasks started, except the
    /// ones you pinned).
    @ViewBuilder
    private func groupedList() -> some View {
        let now = Date.now, filter = filter, context = filterContext
        let date = { (session: Session) in store.listDate(session, now: now) }
        let groupsShown = store.sessionGroupsAvailable
        let groups = SessionSidebar.groups(sessions, pinned: store.pinnedSessionIds,
                                           groups: groupsShown ? store.sessionGroups : [], groupIds: groupsShown ? store.sessionGroupIds : [:],
                                           date: date, recentSince: now.addingTimeInterval(-Self.recentWindow),
                                           shows: { filter.includes($0, context: context) })
        if !groups.pinned.isEmpty {
            CollapsibleListSection("Pinned", key: "pinned", count: Self.flatten(groups.pinned).count, drawer: isDrawer) {
                outline(groups.pinned)
            }
            .sessionActivity(activity(groups.pinned))
            .acceptsSessions { place($0, in: .pinned) }
        }
        // The user's groups, under Pinned: each keeps its sessions whatever their state.
        ForEach(groups.grouped) { section in groupSection(section) }
        if grouping == .folder {
            // What the usual list keeps in view (running, and used in the last two days), by folder.
            folderSections(SessionSidebar.folders(groups.active + groups.recent, date: date))
        } else {
            if !groups.active.isEmpty {
                // Titled (and so foldable) to set it apart from Pinned and the groups, and from the agents above them.
                if !groups.pinned.isEmpty || !groups.grouped.isEmpty || !store.agentProfiles.isEmpty {
                    CollapsibleListSection("Active", key: "active", count: Self.flatten(groups.active).count, drawer: isDrawer) {
                        outline(groups.active)
                    }
                    .acceptsSessions { place($0, in: .list) }
                } else {
                    Section { outline(groups.active) }
                }
            } else if Self.dragsSessions, !groups.grouped.isEmpty {
                // Still titled while every running session is in a group: where one is dropped to
                // take it out of its group.
                CollapsibleListSection("Active", key: "active", count: 0, drawer: isDrawer) {
                    Text("No sessions. Drag one here to take it out of its group.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
                .acceptsSessions { place($0, in: .list) }
            }
            // Resting or stopped, used in the last two days: still in view, one tap away.
            if !groups.recent.isEmpty {
                CollapsibleListSection("Recent", key: "recent", count: Self.flatten(groups.recent).count, drawer: isDrawer) {
                    outline(groups.recent)
                }
                .acceptsSessions { place($0, in: .list) }
            }
        }
        // Put to rest by the idle cleaner: in the list itself, the ones that went to sleep last first.
        if !groups.resting.isEmpty {
            CollapsibleListSection("Resting", key: "resting", count: Self.flatten(groups.resting).count, drawer: isDrawer) {
                outline(groups.resting)
            }
            .acceptsSessions { place($0, in: .list) }
        }
        Section {
            olderFolder("Stopped", systemImage: "stop.circle", groups.stopped, section: .stopped)
            Button {
                AppHaptics.light()
                olderSessions = .archived
            } label: {
                folderRow("Archived", systemImage: "archivebox", count: nil, unread: false)
            }
            .buttonStyle(.plain)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 36 }
            .listRowSeparatorTint(isDrawer ? Self.separatorTint : nil)
        }
    }

    /// A group of the user's: folds like the other sections; its menu renames it, moves it up or
    /// down among the groups, or deletes it. A session row dragged onto its title moves in.
    private func groupSection(_ section: SessionSidebar.GroupSection) -> some View {
        let siblings = store.siblingGroups(of: section.id).map(\.id)
        let index = siblings.firstIndex(of: section.id)
        return CollapsibleListSection(verbatim: section.group.name, key: "group.\(section.id)", count: Self.flatten(section.nodes).count, drawer: isDrawer) {
            if section.nodes.isEmpty {
                // Still listed, so it can be renamed or deleted.
                Text(section.pinned > 0 ? "Its sessions are pinned, so they're in Pinned." : Self.emptyGroupHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            } else {
                outline(section.nodes)
            }
        } accessory: {
            Menu {
                Button("Rename Group…", systemImage: "pencil") {
                    AppHaptics.light()
                    renamingGroup = section.group
                }
                if let index, siblings.count > 1 {
                    Divider()
                    if index > 0 {
                        Button("Move Up", systemImage: "arrow.up") {
                            AppHaptics.selection()
                            Task { await store.moveGroup(section.id, by: -1) }
                        }
                    }
                    if index < siblings.count - 1 {
                        Button("Move Down", systemImage: "arrow.down") {
                            AppHaptics.selection()
                            Task { await store.moveGroup(section.id, by: 1) }
                        }
                    }
                    Button("Reorder Groups…", systemImage: "arrow.up.arrow.down") {
                        AppHaptics.light()
                        reorderingGroups = section.group
                    }
                    Divider()
                }
                Button("Delete Group", systemImage: "trash", role: .destructive) {
                    AppHaptics.warning()
                    deletingGroup = section.group
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 28, height: 22)
                    .contentShape(Rectangle())
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            #endif
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Group Actions"))
            .accessibilityIdentifier("session-group-menu")
        }
        .sessionActivity(activity(section.nodes))
        .acceptsSessions { place($0, in: .group(section.id)) }
    }

    #if os(iOS)
    /// Rows drag onto section titles (on the Mac, draggable rows locked the sidebar).
    private static let dragsSessions = true
    private static let emptyGroupHint: LocalizedStringKey = "No sessions. Drag one onto its name, or move it here from its menu."
    #else
    private static let dragsSessions = false
    private static let emptyGroupHint: LocalizedStringKey = "No sessions. Move one here from its menu."
    #endif

    /// How many of these sessions work and need you, for their section's title.
    private func activity(_ nodes: [SessionTreeNode<Session>]) -> (Date) -> SessionSidebar.Activity {
        let context = filterContext
        return { [store] date in SessionSidebar.activity(of: nodes, context: context, now: store.presenceDate(date)) }
    }

    /// Where a session row dropped on a section's title goes.
    private enum SessionPlace {
        case pinned
        case group(String)
        /// The list itself: out of Pinned and of its group, listed by its state.
        case list
    }

    /// A session row dropped on a section's title: pinned, put in that group (out of Pinned), or
    /// taken out of Pinned and of its group. False when it's already there, or listed in a group
    /// only by being under a session in it (it goes with that session).
    private func place(_ items: [String], in place: SessionPlace) -> Bool {
        guard let id = items.lazy.compactMap(SessionDrag.sessionId).first, store.sessions[id] != nil else { return false }
        let pinned = store.isPinned(id)
        let change: (() async -> Void)?
        switch place {
        case .pinned:
            change = pinned ? nil : { await store.setPinned(id, true) }
        case .group(let groupId):
            let inGroup = store.groupId(of: id) == groupId
            change = !pinned && inGroup ? nil : {
                if pinned { await store.setPinned(id, false) }
                if !inGroup { await store.moveToGroup(id, groupId) }
            }
        case .list:
            let grouped = store.isGroupedOnItsOwn(id)
            change = !pinned && !grouped ? nil : {
                if pinned { await store.setPinned(id, false) }
                if grouped { await store.moveToGroup(id, nil) }
            }
        }
        guard let change else { return false }
        AppHaptics.confirm()
        Task { await change() }
        return true
    }

    /// The list by folder: a section per folder, folding like the others, each remembered apart.
    @ViewBuilder
    private func folderSections(_ folders: [SessionSidebar.FolderSection]) -> some View {
        ForEach(folders) { folder in
            CollapsibleListSection(verbatim: folder.title, key: "folder.\(folder.id)", count: Self.flatten(folder.nodes).count, drawer: isDrawer) {
                outline(folder.nodes)
            }
            .sessionActivity(activity(folder.nodes))
            .acceptsSessions { place($0, in: .list) }
        }
    }

    /// The Stopped row, counting the sessions not in Recent; its window lists them all (and the
    /// resting and archived ones). Hidden while empty.
    @ViewBuilder
    private func olderFolder(_ title: LocalizedStringKey, systemImage: String, _ group: [SessionTreeNode<Session>],
                             section: OlderSessionsSection) -> some View {
        if !group.isEmpty {
            let flat = Self.flatten(group)
            Button {
                AppHaptics.light()
                olderSessions = section
            } label: {
                folderRow(title, systemImage: systemImage, count: flat.count, unread: flat.contains { $0.unreadSince != nil })
            }
            .buttonStyle(.plain)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 36 }
            .listRowSeparatorTint(isDrawer ? Self.separatorTint : nil)
        }
    }

    /// A search looks through every session, whatever the filter: it's how you find one.
    @ViewBuilder
    private func searchResults() -> some View {
        ForEach(sessions) { session in row(session) }
        let archived = archivedMatches
        if !archived.isEmpty || archivedSearch?.isLoading == true {
            Section("Archived") {
                ForEach(archived) { session in archivedRow(session) }
                if archivedSearch?.isLoading == true {
                    Label {
                        Text("Searching the archive…").foregroundStyle(.secondary)
                    } icon: {
                        HappierSpinner(size: HappierSpinner.mini)
                    }
                    .font(.subheadline)
                    .listRowSeparator(.hidden)
                }
            }
        }
        MessageSearchSection(results: messageSearch, open: openMessage)
    }

    private func archivedRow(_ session: Session) -> some View {
        Button {
            AppHaptics.selection()
            openArchived(session)
        } label: {
            SessionRow(session: session).equatable()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .archivedActions(session, store: store) { archivedSearch?.remove(session.id) }
    }

    /// A filter other than the usual one: what it keeps, one flat list, newest first.
    @ViewBuilder
    private func filteredList() -> some View {
        let names = agentNames
        if let summary = filter.summary(agentName: { names[$0] }) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                Text("Filtered: \(summary)").lineLimit(1)
                Text(verbatim: "·")
                Button("Clear") {
                    AppHaptics.light()
                    changeFilter { $0.clear() }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.userBubble)
                .fontWeight(.semibold)
                .accessibilityIdentifier("session-filter-clear")
                Spacer(minLength: 0)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .listRowSeparator(.hidden)
            .accessibilityIdentifier("session-filter-summary")
        }
        let now = Date.now
        let found = filteredSessions.sorted { store.listDate($0, now: now) > store.listDate($1, now: now) }
        if grouping == .folder {
            ForEach(SessionSidebar.folders(found, date: { store.listDate($0, now: now) })) { folder in
                CollapsibleListSection(verbatim: folder.title, key: "folder.\(folder.id)", count: folder.nodes.count, drawer: isDrawer) {
                    ForEach(folder.nodes) { node in
                        if node.item.archivedAt != nil { archivedRow(node.item) } else { row(node.item) }
                    }
                }
                .sessionActivity(activity(folder.nodes))
            }
        } else {
            ForEach(found) { session in
                if session.archivedAt != nil { archivedRow(session) } else { row(session) }
            }
        }
        if filter.includesArchived, archivedSearch?.isLoading == true {
            HappierSpinner(size: HappierSpinner.mini).listRowSeparator(.hidden)
        }
    }

    /// Every agent a session can be filtered by: yours, and any a session works as.
    private var agentNames: [String: String] {
        var names: [String: String] = [:]
        for session in sessions { if let agent = session.agentIdentity { names[agent.id] = agent.name } }
        for profile in store.agentProfiles { names[profile.id] = profile.name }
        return names
    }

    /// The Stopped and Archived rows: an icon, a count, and a chevron to their window.
    private func folderRow(_ title: LocalizedStringKey, systemImage: String, count: Int?, unread: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: Self.drawerAvatar)
            Text(title).font(.subheadline.weight(.medium))
            if let count {
                Text(count, format: .number).foregroundStyle(.secondary)
            }
            if unread {
                Circle().fill(Color.userBubble).frame(width: 8, height: 8).accessibilityLabel(Text("Unread"))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, isDrawer ? 9 : 7)
        .contentShape(Rectangle())
    }

    private static func flatten(_ nodes: [SessionTreeNode<Session>]) -> [Session] {
        nodes.flatMap { [$0.item] + flatten($0.children ?? []) }
    }
}

extension View {
    /// Swipe right: read / unread. Swipe left: archive. Long press: everything, plus pin and stop.
    func rowActions(_ session: Session, store: HappierStore, openInWindow: (() -> Void)? = nil, rename: (() -> Void)? = nil, moveInto: (() -> Void)? = nil, newSession: (() -> Void)? = nil,
                    newGroup: (() -> Void)? = nil) -> some View {
        let unread = session.unreadSince != nil
        let pinned = store.isPinned(session.id)
        return self
            .swipeActions(edge: .leading) {
                Button {
                    AppHaptics.selection()
                    Task { await store.setRead(session.id, unread) }
                } label: {
                    Label(unread ? "Read" : "Unread", systemImage: unread ? "message" : "message.badge")
                }
                .tint(.userBubble)
            }
            .swipeActions(edge: .trailing) {
                Button {
                    AppHaptics.confirm()
                    Task { await store.archive(session.id) }
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .tint(.indigo)
            }
            .contextMenu {
                if let newSession {
                    Button("New Session in This Folder", systemImage: "plus.bubble") {
                        AppHaptics.light()
                        newSession()
                    }
                    .disabled(NewSessionDraft(inFolderOf: session) == nil)
                    .accessibilityIdentifier("new-session-in-folder")
                }
                if let openInWindow {
                    Button("Open in New Window", systemImage: "macwindow.badge.plus") { openInWindow() }
                    Divider()
                }
                // Auto read: off from here; on only once the conversation is loaded, so what's
                // already in it isn't read out.
                if MessageSpeaker.shared.autoReadSessionId == session.id {
                    Button("Stop Reading New Messages", systemImage: "speaker.slash") {
                        MessageSpeaker.shared.toggleAutoRead(session.id, store: store)
                    }
                } else if store.transcripts[session.id]?.isLoaded == true {
                    Button("Read New Messages Aloud", systemImage: "speaker.wave.2") {
                        MessageSpeaker.shared.toggleAutoRead(session.id, store: store)
                    }
                }
                if let path = session.path {
                    FolderColorMenu(path: path, current: store.accountSettings?.folderColor(for: path)) { color in
                        store.setFolderColor(color, forPath: path)
                    }
                }
                Button(unread ? "Mark as Read" : "Mark as Unread", systemImage: unread ? "message" : "message.badge") {
                    AppHaptics.selection()
                    Task { await store.setRead(session.id, unread) }
                }
                Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                    AppHaptics.selection()
                    Task { await store.setPinned(session.id, !pinned) }
                }
                Button(session.notificationsMuted ? "Turn On Notifications" : "Mute Notifications",
                       systemImage: session.notificationsMuted ? "bell" : "bell.slash") {
                    AppHaptics.selection()
                    Task { await store.setNotificationsMuted(!session.notificationsMuted, in: session.id) }
                }
                if let rename {
                    Button("Rename…", systemImage: "pencil") {
                        AppHaptics.light()
                        rename()
                    }
                }
                if let moveInto {
                    Button("Move Into…", systemImage: "arrow.turn.down.right") {
                        AppHaptics.light()
                        moveInto()
                    }
                }
                if let newGroup, store.sessionGroupsAvailable {
                    SessionGroupMenu(session: session, store: store, newGroup: newGroup)
                }
                if let parentId = session.parentSessionId, store.sessions.keys.contains(parentId) {
                    Button {
                        AppHaptics.confirm()
                        Task { await store.nest(session.id, under: nil) }
                    } label: {
                        Label("Detach from Parent", image: "DetachFromParent")
                    }
                }
                SessionIDMenu(sessionId: session.id,
                              providerName: session.agentId.flatMap { Agent.displayNames[$0] },
                              providerSessionId: session.vendorSessionId)
                if session.status() != .offline {
                    RestartSessionButton(sessionId: session.id)
                    Button("Stop Session", systemImage: "power", role: .destructive) {
                        AppHaptics.warning()
                        store.requestStop(session.id)
                    }
                } else {
                    ResumeSessionButton(sessionId: session.id)
                }
                Button("Archive", systemImage: "archivebox") {
                    AppHaptics.confirm()
                    Task { await store.archive(session.id) }
                }
                DeleteSessionButton(session: session, store: store)
            } preview: {
                SessionMenuPreview(session: session)
            }
            #if os(iOS)
            // The lifted row is the glass capsule below, not a white plate around the row.
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 22, style: .continuous))
            #endif
    }
}

/// Opens the choice of running sessions to put to rest (`RestSessionsSheet`), from the session
/// list's toolbar; while they're being put to rest it shows how far along it is.
struct RestAllButton: View {
    /// Opens the list of sessions to choose from.
    let choose: () -> Void
    @Environment(HappierStore.self) private var store

    var body: some View {
        if let progress = store.restingProgress {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("\(progress.done)/\(progress.total)").monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Putting sessions to rest, \(progress.done) of \(progress.total)"))
        } else {
            // Always in its place, so it's found; with nothing running there's nothing to do.
            Button {
                AppHaptics.light()
                choose()
            } label: {
                Label("Put Sessions to Rest", systemImage: "moon.zzz")
            }
            .disabled(store.restCandidates.isEmpty)
            .accessibilityIdentifier("rest-all-sessions")
            .help(Text("Choose running sessions to put to rest. Each one wakes when you need it."))
        }
    }
}

/// One action shared by the stopped or resting status pill, conversation menu and sidebar rows.
struct ResumeSessionButton: View {
    let sessionId: String
    @Environment(HappierStore.self) private var store

    var body: some View {
        if let session = store.sessions[sessionId], session.archivedAt == nil, session.status() == .offline {
            let resuming = store.resumingSessions[sessionId] == true
            // The same reconnect either way; a session put to rest is woken rather than reactivated.
            let title: LocalizedStringKey = session.isResting
                ? (resuming ? "Waking…" : "Wake Session")
                : (resuming ? "Reactivating…" : "Reactivate Session")
            Button(title, systemImage: "play.circle") {
                AppHaptics.light()
                Task { await store.resumeSession(sessionId) }
            }
            .disabled(resuming)
            .accessibilityIdentifier("resume-session-\(sessionId)")
            .help(Text("Reconnect this conversation on its computer without sending a message."))
        }
    }
}

/// For a session that stopped answering: stops it and starts it again on its computer, keeping the
/// conversation. Next to Stop Session, in the row's menu and the chat's.
struct RestartSessionButton: View {
    let sessionId: String
    @Environment(HappierStore.self) private var store

    var body: some View {
        let restarting = store.restartingSessions.contains(sessionId)
        let title: LocalizedStringKey = restarting ? "Restarting…" : "Restart Session"
        Button(title, systemImage: "arrow.clockwise.circle") {
            AppHaptics.light()
            Task { await store.restartSession(sessionId) }
        }
        .disabled(restarting)
        .accessibilityIdentifier("restart-session-\(sessionId)")
        .help(Text("Stop this session and start it again on its computer. The conversation is kept."))
    }
}

/// The row lifted by a long press: on a Liquid Glass capsule with room around it. Built from the
/// session alone (previews are drawn outside the app's view tree, without its environment).
private struct SessionMenuPreview: View {
    let session: Session

    var body: some View {
        HStack(spacing: 10) {
            SessionAvatar(session: session, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(session.displayPath ?? session.host ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            Text(ChatDate.listLabel(session.sortDate))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 340)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

extension SessionListView {
    var body: some View {
        list.offlineNotice()
    }

    /// The agents head the list (not while searching) once the account has agents.
    private var showsAgents: Bool { query.isEmpty && !store.agentProfiles.isEmpty }

    /// What the list shows when it has no sessions to show.
    private enum EmptyState { case noMatchingSessions, loading, noSearchResults, noSessions }

    /// Loading, no sessions, or none matching the filter or search; nil while there are sessions.
    private var emptyState: EmptyState? {
        if !filter.isDefault, query.isEmpty, filteredSessions.isEmpty, archivedSearch?.isLoading != true { return .noMatchingSessions }
        guard sessions.isEmpty,
              query.isEmpty || (archivedMatches.isEmpty && archivedSearch?.isLoading != true && !messageSearch.hasContent) else { return nil }
        if store.isLoadingSessions { return .loading }
        return query.isEmpty ? .noSessions : .noSearchResults
    }

    /// The empty state: over the list when it is otherwise empty, under the agents when it shows
    /// them (`showsAgents`).
    @ViewBuilder
    private func emptyStateView(_ state: EmptyState) -> some View {
        switch state {
        case .noMatchingSessions:
            ContentUnavailableView {
                Label("No Matching Sessions", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Nothing in your sessions matches this filter.")
            } actions: {
                Button("Clear Filter") { changeFilter { $0.clear() } }
            }
        case .loading:
            HappierSpinner(size: HappierSpinner.hero)
        case .noSearchResults:
            ContentUnavailableView.search(text: query)
        case .noSessions:
            ContentUnavailableView("No Sessions", systemImage: "bubble.left.and.text.bubble.right",
                                   description: Text("Start an agent with the Happier CLI on your computer and it will show up here."))
        }
    }

    private var list: some View {
        List(selection: isDrawer ? .constant(nil) : Binding(get: { selection }, set: { next in
            if next != selection { AppHaptics.selection() }
            selection = next
        })) {
            if store.undecryptableSessionCount > 0 {
                Label("\(store.undecryptableSessionCount) sessions can't be read on this device", systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if showsAgents {
                AgentsSection(sessions: listed.sessions ?? store.sessionList, drawer: isDrawer, selection: selection, open: open,
                              newSession: { newSessionAgent = $0 }, editing: $editingAgents)
            }
            if !query.isEmpty {
                searchResults()
            } else if filter.isDefault {
                groupedList()
            } else {
                filteredList()
            }
            if showsAgents, let emptyState {
                // Under the agents, not over them.
                emptyStateView(emptyState)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        #if os(macOS)
        // The system sidebar: a floating Liquid Glass panel over the desktop, like Messages.
        .listStyle(.sidebar)
        #else
        // The drawer has its own look; beside the conversation (iPad, iPhone sideways) it is the
        // same glass sidebar as on the Mac.
        .modifier(SessionListStyle(drawer: isDrawer))
        // Compact drawer rows are shorter than the standard 44 pt list row.
        .environment(\.defaultMinListRowHeight, isDrawer ? 0 : 44)
        // The agents' Edit: only their rows can move, so only they show handles.
        .environment(\.editMode, .constant(editingAgents && query.isEmpty ? .active : .inactive))
        #endif
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Claude/ChatGPT sidebar footer: the account, and starting a new session; the iPhone
            // drawer, the iPad sidebar and the Mac sidebar alike, so New Session is always in view.
            HStack {
                Button {
                    AppHaptics.light()
                    showAccount = true
                } label: {
                    Image(systemName: "gearshape").font(.title2)
                }
                .buttonStyle(.glass)
                .glassHover()
                .buttonBorderShape(.circle)
                // As tall as New Session beside it.
                .controlSize(.large)
                .accessibilityLabel(Text("Settings"))
                #if os(iOS)
                // Oído at hand all day (the Mac has its menu bar item).
                OidoQuickButton()
                #endif
                Spacer()
                // A new, empty conversation where the composer starts the session.
                Button {
                    AppHaptics.light()
                    if let onOpen { onOpen(NewChat.id) } else { selection = NewChat.id }
                } label: {
                    Label("New Session", systemImage: "plus").font(.body.weight(.semibold))
                }
                .buttonStyle(.glassProminent)
                .glassHover()
                .controlSize(.large)
                .keyboardShortcut("n", modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .overlay {
            if !showsAgents, let emptyState { emptyStateView(emptyState) }
        }
        .navigationTitle(isDrawer ? "Happier" : "Sessions")
        #if os(iOS)
        // The system field under the title: always there beside the conversation (iPad, iPhone
        // sideways), like the Mac's; in the drawer it comes down with a pull, like Mail's.
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: isDrawer ? .automatic : .always), prompt: "Search Sessions")
        #else
        // Inside the sidebar, like Messages: the conversation has its own search.
        .searchable(text: $query, placement: .sidebar, prompt: "Search Sessions")
        #endif
        .refreshable { await store.refreshSessions(userInitiated: true) }
        .task(id: query) { await messageSearch.update(query: query, store: store) }
        .task(id: needsArchive) {
            // Searching (or a filter showing archived sessions) looks in the archive too; it is
            // fetched for that and let go after.
            guard needsArchive else {
                archivedSearch = nil
                return
            }
            let archive = ArchivedSessions()
            archivedSearch = archive
            await archive.loadAll(from: store)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    AppHaptics.light()
                    showRelay = true
                } label: {
                    ConnectionDot(connection: store.connection)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .accessibilityHint(Text("Shows the relay you're connected to"))
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    AppHaptics.light()
                    showNotifications = true
                } label: {
                    Label("Notifications", systemImage: unseenNotifications ? "bell.badge" : "bell")
                }
                .help(Text("Notifications"))
            }
            // Where the window has its Tasks panel, its own button (beside the conversation) opens it.
            if !tasksPanelAvailable {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        AppHaptics.light()
                        showTasks = true
                    } label: {
                        Label("Tasks", systemImage: "checklist")
                    }
                    .help(Text("Tasks for you and your agents"))
                }
            }
            ToolbarItem(placement: .primaryAction) {
                RestAllButton { restChoice = store.restCandidates }
            }
            ToolbarItem(placement: .primaryAction) {
                // A tap switches the chosen filter on and off; holding it shows the shortcuts,
                // "Edit Filter…" and "Clear Filter" (the system menu of a primary-action button).
                Menu {
                    ForEach(SessionListFilter.shortcuts) { shortcut in
                        Button {
                            AppHaptics.selection()
                            changeFilter { $0.choose(shortcut.filter) }
                        } label: {
                            if filterChoice.chosen == shortcut.filter {
                                Label(shortcut.title, systemImage: "checkmark")
                            } else {
                                Text(shortcut.title)
                            }
                        }
                    }
                    Divider()
                    Button {
                        changeGrouping(grouping == .folder ? .status : .folder)
                    } label: {
                        Label("Group by Folder", systemImage: grouping == .folder ? "checkmark" : "folder")
                    }
                    .accessibilityIdentifier("session-group-by-folder")
                    Divider()
                    Button("Edit Filter…", systemImage: "slider.horizontal.3") { showFilter = true }
                    Button("Clear Filter", systemImage: "xmark.circle") {
                        // The usual list, with nothing chosen.
                        changeFilter { $0.choose(.default) }
                    }
                    .disabled(!filterChoice.hasChosenFilter)
                } label: {
                    Label {
                        Text("Filter")
                    } icon: {
                        FilterButtonIcon(filled: !filter.isDefault, dot: filterChoice.hasChosenFilter,
                                         tint: filter.isDefault ? nil : Color.userBubble)
                    }
                } primaryAction: {
                    switchFilter()
                }
                .accessibilityValue(filter.isDefault ? Text("Default") : Text("Filtered"))
                .accessibilityHint(Text("Switches your filter on or off. Touch and hold for more."))
                .accessibilityIdentifier("session-filter-button")
                .help(Text("Click to switch your filter on or off; hold for shortcuts and to edit it"))
                .popover(isPresented: $showFilter) {
                    SessionFilterView(filter: Binding(get: { filterChoice.chosen }, set: { next in changeFilter { $0.choose(next) } }),
                                      grouping: Binding(get: { grouping }, set: { changeGrouping($0) }),
                                      agents: agentNames)
                        #if os(macOS)
                        .frame(width: 340, height: 520)
                        #endif
                }
            }

        }
        .sheet(item: $restChoice) { request in
            RestSessionsSheet(request: request)
        }
        .sheet(item: $olderSessions) { section in
            OlderSessionsView(initial: section) { session in openOlder(session) }
                #if os(macOS)
                .frame(minWidth: 460, minHeight: 560)
                #endif
        }
        .modifier(CombineSessions(request: $combining) { targetId in
            withAnimation(.smooth(duration: 0.2)) { _ = expanded.insert(targetId) }
        })
        .modifier(RenameSessionAlert(session: $renaming))
        .modifier(SessionGroupAlerts(newGroupFor: $groupingSession, renaming: $renamingGroup, deleting: $deletingGroup))
        .sheet(item: $newSessionDraft) { draft in
            NewSessionSheet(draft: draft)
        }
        .sheet(item: $newSessionAgent) { agent in
            NewSessionSheet(preselectedAgentId: agent.id)
        }
        .sheet(item: $reorderingGroups) { group in
            SessionGroupOrderSheet(groupId: group.id)
                #if os(macOS)
                .frame(minWidth: 340, minHeight: 420)
                #endif
        }
        #if os(macOS)
        .task(id: springTarget) {
            guard let target = springTarget else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, springTarget == target else { return }
            selection = target
        }
        #endif
        .sheet(item: $movingInto) { session in
            MoveIntoSheet(session: session) { target in
                // Asked once the sheet is gone, so the question has somewhere to show.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    combine(session, into: target)
                }
            }
        }
        .onChange(of: inbox.showRequested, initial: true) { _, requested in
            guard requested else { return }
            inbox.showRequested = false
            showNotifications = true
        }
        .sheet(isPresented: $showNotifications) {
            NotificationCenterView()
                #if os(macOS)
                .frame(minWidth: 420, minHeight: 480)
                #endif
        }
        // Where there's no Tasks panel (iPhone), a widget's or link's request opens the sheet.
        .onChange(of: store.tasksRequest, initial: true) { _, request in
            if request != nil, !tasksPanelAvailable { showTasks = true }
        }
        .sheet(isPresented: $showTasks) {
            TasksView(openSessionId: MainView.sessionId(in: selection))
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 560)
                #endif
        }
        .task { await inbox.refresh() }
        // The agents atop the list (and their photos) are read when it shows; later changes come with
        // the account's KV catch-up.
        .task {
            await store.refreshAgentProfiles()
            await store.refreshAgentPhotos()
        }
        .task { await listed.follow(store) }
        .onChange(of: selection) { closed, now in
            guard now == nil, let closed, closed != NewChat.id else { return }
            justClosed = closed
            justClosedGlow = true
            Task {
                // Once the list is back on screen, then slowly to its usual color.
                try? await Task.sleep(for: .milliseconds(350))
                withAnimation(.easeOut(duration: 2)) { justClosedGlow = false }
                try? await Task.sleep(for: .seconds(2))
                if justClosed == closed, !justClosedGlow { justClosed = nil }
            }
        }
        .sheet(isPresented: $showAccount) {
            NavigationStack { SettingsView() }
                #if os(macOS)
                .frame(minWidth: 420, minHeight: 460)
                #endif
        }
        .sheet(isPresented: $showRelay) {
            NavigationStack { RelaySheet() }
                .presentationDetents([.medium, .large])
                #if os(macOS)
                .frame(minWidth: 420, minHeight: 440)
                #endif
        }
    }
}

/// The one-glance session row, the same in every list (drawer, sidebar, the older-sessions window,
/// pickers), in two lines: the title with the time (or what the agent is up to), then who works in
/// it and its folder. The agent icon carries the unread dot. Token counts are in Session Info.
struct SessionRow: View, Equatable {
    let session: Session
    @Environment(HappierStore.self) private var store
    @Environment(\.sessionListOnScreen) private var onScreen
    @State private var speaker = MessageSpeaker.shared

    /// Redrawn when its own session changes, not every time any session in the list does.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session == rhs.session
    }

    var body: some View {
        // Hidden under the conversation, the row's clock waits; it refreshes when the list shows.
        TimelineView(.periodic(from: .now, by: onScreen ? 30 : 3_600)) { context in
            row(now: context.date)
        }
        .accessibilityElement(children: .combine)
    }

    private func row(now: Date) -> some View {
        // A resting session fades; what needs you in it (the unread dot, the task mark) doesn't.
        let fade = session.isResting ? Self.restingOpacity : 1
        return HStack(alignment: .center, spacing: SessionListView.avatarGap) {
            SessionAvatar(session: session, size: SessionListView.drawerAvatar)
                .opacity(fade)
                .overlay(alignment: .topLeading) {
                    if session.unreadSince != nil {
                        Circle()
                            .fill(Color.userBubble)
                            .frame(width: 8, height: 8)
                            .background(Circle().fill(.background).padding(-1.5))
                            .offset(x: -2, y: -1)
                            .accessibilityLabel(Text("Unread"))
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .center, spacing: 4) {
                    if store.taskContext.hasOpenTask(session.id) {
                        OpenTaskMark().font(.caption2)
                    }
                    Group {
                        if store.isPinned(session.id) {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(Text("Pinned"))
                        }
                        if session.notificationsMuted {
                            Image(systemName: "bell.slash.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(Text("Notifications muted"))
                        }
                        if session.archivedAt != nil {
                            Image(systemName: "archivebox.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(Text("Archived"))
                        }
                        if session.isResting {
                            RestingMark().font(.caption2)
                        }
                        if speaker.autoReadSessionId == session.id {
                            // New messages of this session are read aloud (moving while it reads).
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.caption2)
                                .foregroundStyle(Color.userBubble)
                                .symbolEffect(.variableColor.iterative, isActive: speaker.speakingText != nil && onScreen)
                                .accessibilityLabel(Text("Reading new messages aloud"))
                        }
                        Text(session.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    .opacity(fade)
                    Spacer(minLength: 4)
                    RowTrailing(session: session, now: now)
                        .opacity(fade)
                }
                HStack(spacing: 6) {
                    // Left, where it works (the folder's own name); right, who works there:
                    // the agent it works as, by the model it runs on.
                    Text(session.listPlace)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let agent = session.agentIdentity?.name {
                        Text(agent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                    if let model = session.runningModel {
                        ModelPill(word: model.word)
                    }
                }
                .opacity(fade)
            }
        }
    }

    static let restingOpacity = 0.45
}

/// A task still open in the session (written, worked or run there): it counts among what needs
/// you, so it's blue like the unread dot, in the Tasks list's own symbol.
private struct OpenTaskMark: View {
    var body: some View {
        Image(systemName: "checklist")
            .foregroundStyle(Color.userBubble)
            .accessibilityLabel(Text("Open task"))
            .help(Text("Open task"))
    }
}

/// The model a session runs on, in one word under the row's time; the same quiet gray on every row.
private struct ModelPill: View {
    let word: String

    var body: some View {
        Text(word)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.fill.tertiary, in: Capsule())
            .accessibilityLabel(Text("Model \(word)"))
    }
}

/// The right end of the title: an upload in progress, else what the agent is up to, else when the
/// session was last active. One slot, so the row never shifts between them.
private struct RowTrailing: View {
    let session: Session
    let now: Date
    @Environment(HappierStore.self) private var store

    var body: some View {
        if let fraction = store.uploadFraction(inSession: session.id) {
            UploadRing(fraction: fraction)
        } else if StatusMark.shows(session.status(at: store.presenceDate(now))) {
            StatusMark(session: session, now: now)
        } else {
            Text(ChatDate.listLabel(session.sortDate, now: now))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// What the agent is up to, at the right end of the title so the folder below stays in view:
/// working, waiting on you, or a failed turn. Nothing when it's idle.
private struct StatusMark: View {
    let session: Session
    let now: Date
    @Environment(HappierStore.self) private var store

    var body: some View {
        switch session.status(at: store.presenceDate(now)) {
        case .working:
            HappierSpinner(size: HappierSpinner.mini, color: .userBubble)
                .accessibilityLabel(Text("Working"))
        case .permissionRequired:
            mark("hand.raised.fill", .orange, "Needs your approval")
        case .actionRequired:
            mark("questionmark.bubble.fill", .orange, "Waiting for your answer")
        case .failed:
            mark("exclamationmark.triangle.fill", .red, "Turn failed")
        case .idle, .offline:
            EmptyView()
        }
    }

    static func shows(_ status: Session.Status) -> Bool {
        switch status {
        case .idle, .offline: false
        default: true
        }
    }

    private func mark(_ icon: String, _ color: Color, _ label: LocalizedStringKey) -> some View {
        Image(systemName: icon)
            .font(.caption)
            .foregroundStyle(color)
            .accessibilityLabel(Text(label))
            .help(Text(label))
    }
}

private struct ConnectionDot: View {
    let connection: HappierStore.Connection

    var body: some View {
        let (color, label): (Color, LocalizedStringKey) = switch connection {
        case .online: (.green, "Connected")
        case .connecting: (.yellow, "Connecting…")
        case .offline: (.red, "Offline")
        }
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(Text(label))
            .help(Text(label))
    }
}

/// The footer's account window, ordered like Claude's and ChatGPT's settings: who and where you're
/// signed in, your devices, how the app behaves, the key that protects it all, then signing out.
/// The App Store download indicator: a progress ring around a small stop square.
private struct UploadRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.userBubble.opacity(0.2), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(Color.userBubble, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: fraction)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.userBubble)
                .frame(width: 6, height: 6)
        }
        .frame(width: 20, height: 20)
        .accessibilityElement()
        .accessibilityLabel(Text("Uploading \(fraction, format: .percent.precision(.fractionLength(0)))"))
    }
}

/// Tree lines behind a drawer row: from the parent's agent icon down, curving into this row's
/// icon, carrying on to the siblings below; and down from its own icon when its sessions unfold.
private struct TreeLines: View {
    let tree: SessionListView.TreeRow
    let indent: CGFloat
    /// Half the agent icon: where a level's line runs (the icon's centre).
    let radius: CGFloat

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            let bend: CGFloat = 6
            func x(_ level: Int) -> CGFloat { CGFloat(level) * indent + radius }
            var path = Path()
            if tree.depth > 0 {
                // Branches of earlier levels passing by to their later siblings.
                for level in 0..<(tree.depth - 1) where tree.trail.indices.contains(level + 1) && tree.trail[level + 1] {
                    path.move(to: CGPoint(x: x(level), y: 0))
                    path.addLine(to: CGPoint(x: x(level), y: size.height))
                }
                // From the parent: down, a soft bend, and into this icon.
                let parent = x(tree.depth - 1)
                path.move(to: CGPoint(x: parent, y: 0))
                path.addLine(to: CGPoint(x: parent, y: mid - bend))
                path.addQuadCurve(to: CGPoint(x: parent + bend, y: mid), control: CGPoint(x: parent, y: mid))
                path.addLine(to: CGPoint(x: CGFloat(tree.depth) * indent, y: mid))
                if !tree.isLast {
                    path.move(to: CGPoint(x: parent, y: mid - bend))
                    path.addLine(to: CGPoint(x: parent, y: size.height))
                }
            }
            if tree.isOpen {
                path.move(to: CGPoint(x: x(tree.depth), y: mid + radius))
                path.addLine(to: CGPoint(x: x(tree.depth), y: size.height))
            }
            context.stroke(path, with: .color(Color.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// A row of the session list, a session's or an agent's alike, so the two line up: the room
    /// above and below its two lines (inside the row, so tree lines run on into the next one), a
    /// full touch target, the pointer highlight, the list's insets and, in the drawer, a hairline
    /// that starts where the text does. `indent` moves a sub-session in, its hairline with it.
    func sessionListRow(drawer: Bool, indent: CGFloat = 0) -> some View {
        padding(.leading, indent)
            .padding(.vertical, drawer ? 5 : 4)
            // Two compact lines, still a full touch target.
            .frame(minHeight: 44)
            // Lights up under the Apple Pencil or pointer on iPad, like a system list row.
            .pointerHoverRow()
            .listRowInsets(SessionListView.rowInsets(drawer: drawer))
            // iOS hairlines between the drawer's rows, past the icon (the sidebar draws none).
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + indent + 36 }
            .listRowSeparatorTint(drawer ? SessionListView.separatorTint : nil)
    }

    /// A drawer row lifted to be reordered (touch and hold) shows as the drawer's highlight, rounded
    /// and inset like the selected session's, not as the list's square, edge-to-edge cell. The
    /// sidebar already lifts its rows rounded and inset, like its selection.
    @ViewBuilder
    func sessionListRowLift(drawer: Bool) -> some View {
        if drawer {
            contentShape(.dragPreview, DrawerRowHighlight(inset: SessionListView.rowInsets(drawer: true)))
        } else {
            self
        }
    }
}

/// The drawer's row highlight (the selected session, a lifted agent): rounded, 8 pt in from the
/// screen's edges, which the drawer's rows reach. The sidebar draws its own, already inset.
/// A row something can be dropped on, while it's over it: a session (to nest or group) or an agent
/// (a task, to assign it).
struct RowDropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.userBubble, lineWidth: 2)
            .background(Color.userBubble.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, -6)
            .allowsHitTesting(false)
    }
}

struct DrawerRowHighlight: Shape {
    /// How far the frame it's drawn in sits in from those edges: none for a row's background, the
    /// row's insets for its content.
    var inset = EdgeInsets()

    func path(in rect: CGRect) -> Path {
        let edge: CGFloat = 8
        let frame = CGRect(x: rect.minX - inset.leading + edge, y: rect.minY,
                           width: rect.width + inset.leading + inset.trailing - 2 * edge, height: rect.height)
        return RoundedRectangle(cornerRadius: 12, style: .continuous).path(in: frame)
    }
}

#if os(iOS)
private struct SessionListStyle: ViewModifier {
    let drawer: Bool

    func body(content: Content) -> some View {
        if drawer {
            content.listStyle(.plain)
        } else {
            content.listStyle(.sidebar)
        }
    }
}

#endif

/// A section of the session list that folds under its title, like a folder in Files or Notes:
/// tapping the title folds or unfolds it, and folded it shows how many things it keeps (and, for
/// the agents, how many sessions wait for you). The sidebar (iPad, Mac) adds its own disclosure
/// chevron; the drawer draws one after the title. Each device remembers how you left it.
struct CollapsibleListSection<Content: View, Accessory: View>: View {
    private let title: Text
    private let count: Int
    private let drawer: Bool
    private let waiting: Int
    private let content: Content
    private let accessory: Accessory
    /// How many of its sessions work and need you, at a date (`sessionActivity`).
    private var activity: ((Date) -> SessionSidebar.Activity)?
    /// A session row dropped on the title (`acceptsSessions`); true when it moved.
    private var dropSession: (([String]) -> Bool)?
    @AppStorage private var collapsed: Bool
    @State private var dropTargeted = false
    @Environment(\.sessionListOnScreen) private var onScreen

    /// The sessions-need-you count, as on the agents' circles.
    static var waitingColor: Color { Color(red: 0xC2 / 255, green: 0x41 / 255, blue: 0x0C / 255) }

    init(_ title: LocalizedStringKey, key: String, count: Int, drawer: Bool, waiting: Int = 0,
         @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.init(title: Text(title), key: key, count: count, drawer: drawer, waiting: waiting, content: content, accessory: accessory)
    }

    /// A title the user wrote (a group's name) or that comes from the data (a folder's), shown as is.
    init(verbatim title: String, key: String, count: Int, drawer: Bool, waiting: Int = 0,
         @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.init(title: Text(verbatim: title), key: key, count: count, drawer: drawer, waiting: waiting, content: content, accessory: accessory)
    }

    private init(title: Text, key: String, count: Int, drawer: Bool, waiting: Int,
                 @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.count = count
        self.drawer = drawer
        self.waiting = waiting
        self.content = content()
        self.accessory = accessory()
        _collapsed = AppStorage(wrappedValue: false, "happier.sessionList.collapsed.\(key)")
    }

    var body: some View {
        Section(isExpanded: Binding(get: { !collapsed }, set: { collapsed = !$0 })) {
            content
        } header: {
            HStack(spacing: 6) {
                Button {
                    AppHaptics.light()
                    withAnimation(.smooth(duration: 0.25)) { collapsed.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        title.lineLimit(1)
                        if drawer {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .rotationEffect(.degrees(collapsed ? 0 : 90))
                                .accessibilityHidden(true)
                        }
                        if collapsed {
                            Text(count, format: .number).foregroundStyle(.tertiary)
                            if waiting > 0 {
                                Text("\(waiting) waiting")
                                    .font(.caption2.weight(.bold))
                                    .textCase(nil)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Self.waitingColor, in: Capsule())
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(collapsed ? Text("Collapsed") : Text("Expanded"))
                if let activity {
                    // "Working" fades after two minutes without news, as in the rows.
                    TimelineView(.periodic(from: .now, by: onScreen ? 30 : 3_600)) { context in
                        SectionActivityBadges(activity: activity(context.date))
                    }
                }
                if !collapsed { accessory }
            }
            .contentShape(Rectangle())
            .background {
                if dropTargeted { RowDropHighlight() }
            }
            #if os(iOS)
            .modifier(SectionSessionDrop(drop: dropSession, targeted: $dropTargeted))
            #endif
        }
    }

    /// Shows by the title, folded or not, how many of its sessions are working and how many need you.
    func sessionActivity(_ activity: @escaping (Date) -> SessionSidebar.Activity) -> Self {
        var section = self
        section.activity = activity
        return section
    }

    /// A session row dragged onto the title is moved into this section (on iOS, where rows drag).
    func acceptsSessions(_ drop: @escaping ([String]) -> Bool) -> Self {
        var section = self
        section.dropSession = drop
        return section
    }
}

/// A section's title taking a dragged session row, lit while one is held over it.
private struct SectionSessionDrop: ViewModifier {
    let drop: (([String]) -> Bool)?
    @Binding var targeted: Bool

    func body(content: Content) -> some View {
        if let drop {
            content.dropDestination(for: String.self) { items, _ in
                targeted = false
                return drop(items)
            } isTargeted: { over in
                withAnimation(.smooth(duration: 0.15)) { targeted = over }
            }
        } else {
            content
        }
    }
}

/// By a section's title: the working mark with how many sessions are working, then how many need
/// you on the blue of the unread dot. Quiet gray otherwise; nothing while neither.
struct SectionActivityBadges: View {
    let activity: SessionSidebar.Activity

    var body: some View {
        HStack(spacing: 4) {
            if activity.working > 0 {
                HStack(spacing: 3) {
                    HappierSpinner(size: 11, color: .userBubble)
                    Text(activity.working, format: .number)
                }
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .frame(minHeight: 18)
                .background(.fill.tertiary, in: Capsule())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(activity.working) working"))
            }
            if activity.needingYou > 0 {
                Text(activity.needingYou, format: .number)
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Color.userBubble, in: Capsule())
                    .accessibilityLabel(Text("\(activity.needingYou) need you"))
            }
        }
        .textCase(nil)
        .fixedSize()
    }
}

extension CollapsibleListSection where Accessory == EmptyView {
    init(_ title: LocalizedStringKey, key: String, count: Int, drawer: Bool, waiting: Int = 0,
         @ViewBuilder content: () -> Content) {
        self.init(title, key: key, count: count, drawer: drawer, waiting: waiting, content: content, accessory: { EmptyView() })
    }

    init(verbatim title: String, key: String, count: Int, drawer: Bool, waiting: Int = 0,
         @ViewBuilder content: () -> Content) {
        self.init(verbatim: title, key: key, count: count, drawer: drawer, waiting: waiting, content: content, accessory: { EmptyView() })
    }
}

/// "Rename Session": the one rename prompt, from a session row's menu and from a conversation's ⓘ menu.
struct RenameSessionAlert: ViewModifier {
    @Binding var session: Session?
    @Environment(HappierStore.self) private var store
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename Session", isPresented: Binding(get: { session != nil }, set: { if !$0 { session = nil } }), presenting: session) { session in
                TextField("Name", text: $name)
                Button("Save") {
                    AppHaptics.confirm()
                    let name = name
                    Task { await store.rename(session.id, to: name) }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) { AppHaptics.light() }
            }
            .onChange(of: session?.id, initial: true) { name = session?.title ?? "" }
    }
}

extension EnvironmentValues {
    /// False while the session list is loaded but hidden (the iPhone drawer closed under a
    /// conversation): its rows don't animate then. An animating speaker icon there redrew the
    /// whole hidden list as long as reading aloud went on.
    @Entry var sessionListOnScreen = true
}

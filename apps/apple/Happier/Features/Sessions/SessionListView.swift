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
    @Environment(NotificationInbox.self) private var inbox
    /// The bell carries a dot while notifications of sessions still listed are waiting.
    private var unseenNotifications: Bool {
        inbox.notifications.contains { notification in
            notification.sessionId.map { store.sessions[$0]?.archivedAt == nil } ?? true
        }
    }
    @State private var showRelay = false
    /// Stopped and archived sessions open in their own window, at this section.
    @State private var olderSessions: OlderSessionsSection?
    /// The archive, loaded only while a search is running.
    @State private var archivedSearch: ArchivedSessions?
    /// Every conversation with something new, stopped ones included, in one list.
    @State private var unreadOnly = false
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
    /// The row a dragged session is over.
    @State private var dropTarget: String?
    #if os(macOS)
    /// The session a dragged file is held over, opened after a moment (spring-loading).
    @State private var springTarget: String?
    #endif
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    /// The sorted list, refreshed at most twice a second instead of on every message.
    @State private var listed = SessionListSnapshot()

    private var sessions: [Session] {
        let all = listed.sessions ?? store.sessionList
        guard !query.isEmpty else { return all }
        return SessionPins.pinnedFirst(all.filter { $0.matches(query) }, pinned: store.pinnedSessionIds, id: \.id)
    }

    private var archivedMatches: [Session] {
        archivedSearch?.items.filter {
            $0.matches(query) && (!unreadOnly || $0.unreadSince != nil) && !store.deletedSessionIds.contains($0.id)
        } ?? []
    }

    private var unreadSessions: [Session] { sessions.filter { $0.unreadSince != nil } }

    private var isDrawer: Bool { onOpen != nil }

    private func openArchived(_ session: Session) {
        store.openArchived(session)
        onOpen?(session.id)
    }

    /// A session picked in the older-sessions window.
    private func openOlder(_ session: Session) {
        if session.archivedAt != nil {
            openArchived(session)
        } else if let onOpen {
            onOpen(session.id)
        } else {
            selection = session.id
        }
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
            if childCount > 0 { subSessionsButton(session.id, count: childCount) }
        }
        .padding(.leading, CGFloat(depth) * indent)
        // The row's breathing room sits inside it, so tree lines run on into the next row.
        .padding(.vertical, isDrawer ? 8 : 6)
        // Lights up under the Apple Pencil or pointer on iPad, like a system list row.
        .pointerHoverRow()
        .background(alignment: .leading) {
            if let tree { TreeLines(tree: tree, indent: Self.drawerIndent, radius: Self.drawerAvatar / 2) }
        }
        .overlay {
            if dropTarget == session.id {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.userBubble, lineWidth: 2)
                    .background(Color.userBubble.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, -6)
                    .allowsHitTesting(false)
            }
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
                .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 12))
                // iOS hairlines between rows, starting where the text does (past the icon).
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + CGFloat(depth) * indent + 36 }
                .listRowSeparatorTint(Self.separatorTint)
                .listRowBackground(selection == session.id
                    ? RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.1)).padding(.horizontal, 8)
                    : nil)
                .rowActions(session, store: store, openInWindow: openInWindow(session), rename: { startRenaming(session) }, moveInto: { movingInto = session }, newSession: { newSessionDraft = NewSessionDraft(inFolderOf: session) })
                #if os(iOS)
                .modifier(SessionRowDrag(session: session))
                #endif
        } else {
            content
                .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                .tag(session.id)
                .rowActions(session, store: store, openInWindow: openInWindow(session), rename: { startRenaming(session) }, moveInto: { movingInto = session }, newSession: { newSessionDraft = NewSessionDraft(inFolderOf: session) })
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
    private func subSessionsButton(_ id: String, count: Int) -> some View {
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
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(open ? Text("Hide sub-sessions") : Text("Show \(count) sub-sessions"))
    }

    static let drawerIndent: CGFloat = 22
    /// Hairlines just off the background: they order the list without drawing the eye.
    static let separatorTint = Color.primary.opacity(0.08)
    static let drawerAvatar: CGFloat = 26

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
        var id: String { session.id }
    }

    /// The tree as rows: each session, then (when unfolded) the sessions it started, indented.
    private func treeRows(_ nodes: [SessionTreeNode<Session>], depth: Int = 0, trail: [Bool] = []) -> [TreeRow] {
        nodes.enumerated().flatMap { index, node -> [TreeRow] in
            let children = node.children ?? []
            let isLast = index == nodes.count - 1
            let isOpen = expanded.contains(node.id) && !children.isEmpty
            let own = TreeRow(session: node.item, depth: depth, childCount: children.count, isLast: isLast, trail: trail, isOpen: isOpen)
            return isOpen ? [own] + treeRows(children, depth: depth + 1, trail: trail + [!isLast]) : [own]
        }
    }

    private func outline(_ nodes: [SessionTreeNode<Session>]) -> some View {
        ForEach(treeRows(nodes)) { tree in row(tree.session, tree: tree) }
    }

    @ViewBuilder
    private func groupedList() -> some View {
        let now = Date.now
        let groups = SessionSidebar.groups(sessions, pinned: store.pinnedSessionIds) { store.listDate($0, now: now) }
        if !groups.pinned.isEmpty {
            Section("Pinned") { outline(groups.pinned) }
        }
        if !groups.active.isEmpty {
            Section {
                outline(groups.active)
            } header: {
                if !groups.pinned.isEmpty { Text("Active") }
            }
        }
        Section {
            if !groups.inactive.isEmpty {
                let flat = Self.flatten(groups.inactive)
                Button {
                    AppHaptics.light()
                    olderSessions = .inactive
                } label: {
                    folderRow("Inactive", systemImage: "moon.zzz", count: flat.count, unread: flat.contains { $0.unreadSince != nil })
                }
                .buttonStyle(.plain)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 36 }
                .listRowSeparatorTint(isDrawer ? Self.separatorTint : nil)
            }
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

    @ViewBuilder
    private func searchResults() -> some View {
        ForEach(unreadOnly ? unreadSessions : sessions) { session in row(session) }
        let archived = archivedMatches
        if !archived.isEmpty || archivedSearch?.isLoading == true {
            Section("Archived") {
                ForEach(archived) { session in
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
    }

    /// The Inactive and Archived rows: an icon, a count, and a chevron to their window.
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
    func rowActions(_ session: Session, store: HappierStore, openInWindow: (() -> Void)? = nil, rename: (() -> Void)? = nil, moveInto: (() -> Void)? = nil, newSession: (() -> Void)? = nil) -> some View {
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

/// One action shared by the inactive status pill, conversation menu and sidebar rows.
struct ResumeSessionButton: View {
    let sessionId: String
    @Environment(HappierStore.self) private var store

    var body: some View {
        if let session = store.sessions[sessionId], session.archivedAt == nil, session.status() == .offline {
            let resuming = store.resumingSessions[sessionId] == true
            Button(resuming ? "Reactivating…" : "Reactivate Session", systemImage: "play.circle") {
                AppHaptics.light()
                Task { await store.resumeSession(sessionId) }
            }
            .disabled(resuming)
            .accessibilityIdentifier("resume-session-\(sessionId)")
            .help(Text("Reconnect this conversation on its computer without sending a message."))
        }
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
        List(selection: isDrawer ? .constant(nil) : Binding(get: { selection }, set: { next in
            if next != selection { AppHaptics.selection() }
            selection = next
        })) {
            if store.undecryptableSessionCount > 0 {
                Label("\(store.undecryptableSessionCount) sessions can't be read on this device", systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !query.isEmpty {
                searchResults()
            } else if unreadOnly {
                ForEach(unreadSessions) { session in row(session) }
            } else {
                groupedList()
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
            if unreadOnly, query.isEmpty, unreadSessions.isEmpty {
                ContentUnavailableView("No Unread Sessions", systemImage: "checkmark.message",
                                       description: Text("You're all caught up."))
            } else if sessions.isEmpty, query.isEmpty || (archivedMatches.isEmpty && archivedSearch?.isLoading != true) {
                if store.isLoadingSessions {
                    HappierSpinner(size: HappierSpinner.hero)
                } else if !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ContentUnavailableView("No Sessions", systemImage: "bubble.left.and.text.bubble.right",
                                           description: Text("Start an agent with the Happier CLI on your computer and it will show up here."))
                }
            }
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
        .task(id: query.isEmpty) {
            // Searching looks in the archive too; it is fetched for the search and let go after.
            guard !query.isEmpty else {
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
            ToolbarItem(placement: .primaryAction) { UnreadFilterButton(isOn: $unreadOnly) }

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
        .sheet(item: $newSessionDraft) { draft in
            NewSessionSheet(draft: draft)
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
        .task { await inbox.refresh() }
        .task { await listed.follow(store) }
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
/// pickers): the agent icon carrying the unread dot, the title, and the folder underneath.
struct SessionRow: View, Equatable {
    let session: Session
    @Environment(HappierStore.self) private var store
    @State private var speaker = MessageSpeaker.shared

    /// Redrawn when its own session changes, not every time any session in the list does.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session == rhs.session
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            row(now: context.date)
        }
        .accessibilityElement(children: .combine)
    }

    private func row(now: Date) -> some View {
        HStack(alignment: .center, spacing: 10) {
            SessionAvatar(session: session, size: SessionListView.drawerAvatar)
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
                    if store.isPinned(session.id) {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .accessibilityLabel(Text("Pinned"))
                    }
                    if session.archivedAt != nil {
                        Image(systemName: "archivebox.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("Archived"))
                    }
                    if speaker.autoReadSessionId == session.id {
                        // New messages of this session are read aloud (moving while it reads).
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.userBubble)
                            .symbolEffect(.variableColor.iterative, isActive: speaker.speakingText != nil)
                            .accessibilityLabel(Text("Reading new messages aloud"))
                    }
                    Text(session.title)
                        .font(.subheadline.weight(session.unreadSince != nil ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    RowTrailing(session: session, now: now)
                }
                // The session's project folder (or machine), always readable under the title. Its
                // color, if it has one, is the avatar's disc.
                Text(session.displayPath ?? session.host ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.vertical, 2)
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
        } else if StatusMark.shows(session.status(at: now)) {
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

    var body: some View {
        switch session.status(at: now) {
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

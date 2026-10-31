import HappierKit
import SwiftUI

/// Archived sessions, fetched page by page only while something needs them (the older-sessions
/// window or a sidebar search) and released with it: there can be hundreds, and they are encrypted,
/// so the server can't search them for us.
@MainActor
@Observable
final class ArchivedSessions {
    private(set) var items: [Session] = []
    private(set) var isLoading = false
    private(set) var reachedEnd = false
    private(set) var error: String?
    @ObservationIgnored private var cursor: String?

    func loadMore(from store: HappierStore, pageSize: Int = 50) async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await store.archivedSessions(cursor: cursor, limit: pageSize)
            let known = Set(items.map(\.id))
            items += page.sessions.filter { !known.contains($0.id) }
            cursor = page.nextCursor
            reachedEnd = page.nextCursor == nil
        } catch {
            self.error = UserFacingError.message(for: error)
            reachedEnd = true
        }
    }

    /// Everything (the server has no count or search for them).
    func loadAll(from store: HappierStore) async {
        while !reachedEnd, !Task.isCancelled {
            await loadMore(from: store, pageSize: 200)
        }
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
    }
}

enum OlderSessionsSection: String, Identifiable, Hashable {
    case inactive, archived
    var id: String { rawValue }
}

/// Stopped and archived sessions, in their own window: a search, and chips with how many there are
/// in each (or how many match) that jump to their section.
struct OlderSessionsView: View {
    let initial: OlderSessionsSection
    let onOpen: (Session) -> Void
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var archive = ArchivedSessions()
    @State private var query = ""
    @State private var unreadOnly = false

    private func shows(_ session: Session) -> Bool {
        (!unreadOnly || session.unreadSince != nil) && (query.isEmpty || session.matches(query))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                let inactiveTree = SessionSidebar.groups(store.sessionList, pinned: store.pinnedSessionIds) { store.listDate($0) }.inactive
                let filtering = unreadOnly || !query.isEmpty
                let inactiveMatches = filtering ? Self.flatten(inactiveTree).filter(shows) : nil
                let kept = archive.items.filter { !store.deletedSessionIds.contains($0.id) }
                let archived = filtering ? kept.filter(shows) : kept
                List {
                    Section {
                        anchor(.inactive)
                        if let inactiveMatches {
                            ForEach(inactiveMatches) { session in inactiveRow(session) }
                        } else {
                            // Sub-sessions unfolded beneath the session that started them.
                            ForEach(Self.indented(inactiveTree), id: \.session.id) { entry in
                                inactiveRow(entry.session)
                                    .padding(.leading, CGFloat(entry.depth) * 20)
                            }
                        }
                        if inactiveMatches?.isEmpty ?? inactiveTree.isEmpty {
                            placeholder(filtering ? "No matches" : "No inactive sessions")
                        }
                    } header: {
                        Text("Inactive")
                    }
                    Section {
                        anchor(.archived)
                        ForEach(archived) { session in archivedRow(session) }
                        if let error = archive.error {
                            Text(error).foregroundStyle(.red)
                        } else if archive.isLoading {
                            Label {
                                Text("Loading the archive…").foregroundStyle(.secondary)
                            } icon: {
                                HappierSpinner(size: HappierSpinner.mini)
                            }
                            .font(.subheadline)
                            .listRowSeparator(.hidden)
                        } else if archived.isEmpty {
                            placeholder(filtering ? "No matches" : "No archived sessions")
                        }
                    } header: {
                        Text("Archived")
                    }
                }
                .listStyle(.plain)
                // The sidebar's compact rows, shorter than the standard list row.
                .environment(\.defaultMinListRowHeight, 0)
                .safeAreaBar(edge: .top) {
                    HStack(spacing: 8) {
                        chip("Inactive", count: inactiveMatches?.count ?? Self.flatten(inactiveTree).count, loading: false) {
                            withAnimation(.smooth) { proxy.scrollTo(OlderSessionsSection.inactive, anchor: .top) }
                        }
                        chip("Archived", count: archived.count, loading: archive.isLoading) {
                            withAnimation(.smooth) { proxy.scrollTo(OlderSessionsSection.archived, anchor: .top) }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
                .onAppear {
                    guard initial == .archived else { return }
                    Task { @MainActor in proxy.scrollTo(OlderSessionsSection.archived, anchor: .top) }
                }
            }
            #if os(iOS)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .navigationBarTitleDisplayMode(.inline)
            #else
            .searchable(text: $query, prompt: "Search")
            #endif
            .navigationTitle("Inactive & Archived")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { SheetCloseButton() }
                ToolbarItem(placement: .primaryAction) { UnreadFilterButton(isOn: $unreadOnly) }
            }
            .task { await archive.loadAll(from: store) }
        }
    }

    /// An invisible row at the top of a section, for the chips to scroll to.
    private func anchor(_ section: OlderSessionsSection) -> some View {
        Color.clear
            .frame(height: 0)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .accessibilityHidden(true)
            .id(section)
    }

    private func chip(_ title: LocalizedStringKey, count: Int, loading: Bool, action: @escaping () -> Void) -> some View {
        Button {
            AppHaptics.selection()
            action()
        } label: {
            HStack(spacing: 6) {
                Text(title)
                if loading { HappierSpinner(size: HappierSpinner.mini) }
                Text(count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .font(.subheadline.weight(.medium))
            .animation(.smooth, value: count)
        }
        .buttonStyle(.glass)
        .glassHover()
    }

    private func inactiveRow(_ session: Session) -> some View {
        openButton(session)
            .rowActions(session, store: store)
    }

    private func archivedRow(_ session: Session) -> some View {
        openButton(session)
            .archivedActions(session, store: store) { archive.remove(session.id) }
    }

    /// The sidebar's row, with its breathing room, opening the session.
    private func openButton(_ session: Session) -> some View {
        Button {
            AppHaptics.selection()
            dismiss()
            onOpen(session)
        } label: {
            SessionRow(session: session)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    private func placeholder(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .listRowSeparator(.hidden)
    }

    private static func indented(_ nodes: [SessionTreeNode<Session>], depth: Int = 0) -> [(session: Session, depth: Int)] {
        nodes.flatMap { [($0.item, depth)] + indented($0.children ?? [], depth: depth + 1) }
    }

    private static func flatten(_ nodes: [SessionTreeNode<Session>]) -> [Session] {
        nodes.flatMap { [$0.item] + flatten($0.children ?? []) }
    }
}

/// "Delete…" for the user's own stopped sessions (`ui.session.delete`); the store asks first.
struct DeleteSessionButton: View {
    let session: Session
    let store: HappierStore

    var body: some View {
        if session.canDelete {
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive) {
                AppHaptics.warning()
                store.requestDelete(session)
            }
        }
    }
}

extension View {
    /// Unarchive by swipe or long press; delete from the long press.
    func archivedActions(_ session: Session, store: HappierStore, onUnarchive: @escaping () -> Void) -> some View {
        self
            .swipeActions(edge: .leading) {
                Button("Unarchive", systemImage: "tray.and.arrow.up") {
                    AppHaptics.confirm()
                    onUnarchive()
                    Task { await store.unarchive(session.id) }
                }
                .tint(.indigo)
            }
            .contextMenu {
                Button("Unarchive", systemImage: "tray.and.arrow.up") {
                    AppHaptics.confirm()
                    onUnarchive()
                    Task { await store.unarchive(session.id) }
                }
                DeleteSessionButton(session: session, store: store)
            }
    }
}

/// The toolbar's unread filter, the same in the sidebar and the older-sessions window: a funnel
/// that fills and turns the bubble blue while only conversations with something new are shown.
struct UnreadFilterButton: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            AppHaptics.selection()
            withAnimation(.smooth(duration: 0.2)) { isOn.toggle() }
        } label: {
            Label("Unread", systemImage: isOn ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .tint(isOn ? Color.userBubble : nil)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help(Text(isOn ? "Show all sessions" : "Show only unread sessions"))
    }
}

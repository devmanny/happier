import HappierKit
import SwiftUI

struct ChatView: View {
    let sessionId: String
    @Environment(HappierStore.self) private var store
    @State private var draft = ""
    @State private var attachments: [AttachmentDraft] = []
    @State private var dropTargeted = false
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    /// Follow the newest message until the user drags away from it (`ChatScroll`).
    @State private var pinnedToEnd = true
    @State private var followScheduled = false
    @State private var lastGeometry: ChatScroll.Geometry?
    /// Selected transcript item ids; nil when not in selection mode.
    @State private var selected: Set<String>?
    @State private var choosingDestination = false

    private var session: Session? { store.sessions[sessionId] }
    private var queue: [PendingMessage] { store.pendingQueues[sessionId] ?? [] }

    /// Transcript items plus server-queued messages, in one list. A sent message keeps the same id
    /// (`UserText.stableId`) whether it's optimistic, queued or committed, so SwiftUI updates it in
    /// place instead of removing one bubble and inserting another.
    private var items: [ChatItem] {
        var all = store.transcripts[sessionId]?.items ?? []
        let present = Set(all.compactMap { item -> String? in if case .userText(let user) = item { user.localId } else { nil } })
        for message in queue where !present.contains(message.localId) {
            all.append(.userText(UserText(id: UserText.stableId(localId: message.localId), text: message.text,
                                          createdAt: message.createdAt, localId: message.localId, isPending: true)))
        }
        return all
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let working = session?.status(at: context.date) == .working
            ScrollView {
                LazyVStack(spacing: 2) {
                    if store.hasOlderMessages[sessionId] == true {
                        ProgressView()
                            .padding()
                            .task { await store.loadOlder(sessionId) }
                    }
                    let rows = ChatRow.rows(from: items, working: working)
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        let previous = index > 0 ? rows[index - 1] : nil
                        let next = index + 1 < rows.count ? rows[index + 1] : nil
                        if previous.map({ row.createdAt.timeIntervalSince($0.createdAt) > 15 * 60 }) ?? true {
                            Text(ChatDate.separatorLabel(row.createdAt))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.top, 14)
                                .padding(.bottom, 6)
                        }
                        HStack(alignment: .center, spacing: 10) {
                            if let selected, case .item(let item) = row, MessageSelection.isSelectable(item) {
                                Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(selected.contains(item.id) ? Color.userBubble : Color.secondary)
                                    .transition(.move(edge: .leading).combined(with: .opacity))
                            }
                            rowContent(row, previous: previous, next: next, working: working)
                                .allowsHitTesting(selected == nil)
                        }
                        .contentShape(Rectangle())
                        // Row taps toggle selection only in selection mode; otherwise the bubble's own controls win.
                        .gesture(TapGesture().onEnded {
                            guard case .item(let item) = row, MessageSelection.isSelectable(item) else { return }
                            if self.selected?.contains(item.id) == true { self.selected?.remove(item.id) } else { self.selected?.insert(item.id) }
                        }, including: selected == nil ? .subviews : .all)
                        .padding(.top, previous.map { Side($0) == Side(row) ? 0 : 8 } ?? 0)
                        if Side(row) != .center, next.map({ Side($0) != Side(row) }) ?? true {
                            Text(row.createdAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: Side(row) == .user ? .trailing : .leading)
                                .padding(.horizontal, 6)
                                .padding(.top, 2)
                        }
                    }
                    // The running turn's work line already shows progress; the dots cover the gap before it appears.
                    if working, !(rows.last.map { if case .work(_, _, true) = $0 { true } else { false } } ?? false) {
                        HStack {
                            TypingIndicator()
                            Spacer()
                        }
                        .padding(.top, 8)
                        .transition(.scale(scale: 0.6, anchor: .bottomLeading).combined(with: .opacity))
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .scrollTargetLayout()
            }
            // Margins, not padding: the initial bottom positioning aligns the scroll target layout's
            // frame with the viewport, so padding around it became a horizontal offset that ate the
            // left margin until the first scroll.
            .contentMargins(.horizontal, 14, for: .scrollContent)
            .contentMargins(.vertical, 10, for: .scrollContent)
            .scrollPosition($scrollPosition)
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .onChange(of: items.isEmpty, initial: true) { _, isEmpty in
                // On open (including an already-loaded transcript) land on the concrete bottom
                // anchor: it renders the latest messages instead of an estimated (blank) region and
                // settles the horizontal offset on the content margin.
                if !isEmpty {
                    pinnedToEnd = true
                    scrollToBottom(animated: false)
                }
            }
            .onScrollGeometryChange(for: ChatScroll.Geometry.self, of: Self.chatGeometry) { _, new in
                lastGeometry = new
                // Rows measured at their real height, typing dots, a streamed reply or a taller
                // composer moved the end: a pinned chat goes back to it.
                guard ChatScroll.shouldFollow(pinned: pinnedToEnd, geometry: new), !followScheduled else { return }
                followScheduled = true
                scrollToBottom(animated: false)
            }
            .onScrollPhaseChange { old, new, context in
                // Only the user's own drags pin or unpin; programmatic scrolls don't.
                if new == .interacting { pinnedToEnd = false }
                if new == .idle, old == .interacting || old == .decelerating {
                    pinnedToEnd = ChatScroll.isPinned(afterUserScrollTo: Self.chatGeometry(context.geometry))
                }
            }
            .onChange(of: items.last?.id) { _, _ in
                // Your own message just landed (optimistic bubble): follow it to the bottom.
                if case .userText(let message)? = items.last, message.isPending {
                    pinnedToEnd = true
                    scrollToBottom()
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let selected {
                    SelectionBar(count: selected.count) {
                        MessageClipboard.copy(selectedText(working: working))
                        withAnimation(.smooth) { self.selected = nil }
                    } onSend: {
                        choosingDestination = true
                    } onSelectAll: {
                        self.selected = Set(selectableItems(working: working).map(\.id))
                    } onCancel: {
                        withAnimation(.smooth) { self.selected = nil }
                    }
                    .sheet(isPresented: $choosingDestination) {
                        SessionPicker(excluding: sessionId) { destination in
                            let text = selectedText(working: working)
                            withAnimation(.smooth) { self.selected = nil }
                            Task {
                                await store.send(text, to: destination)
                                store.openRequest = destination
                            }
                        }
                    }
                } else {
                Composer(sessionId: sessionId, text: $draft, attachments: $attachments, working: working) { attachments in
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty || !attachments.isEmpty else { return }
                    draft = ""
                    pinnedToEnd = true
                    scrollToBottom()
                    Task { await store.send(text, attachments: attachments, to: sessionId) }
                } onStop: {
                    Task { await store.abort(sessionId) }
                }
                }
            }
        }
        .toolbar { toolbar }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle(session?.title ?? "")
        #if os(macOS)
        .navigationSubtitle(session?.displayPath ?? "")
        #endif
        .overlay {
            if items.isEmpty {
                if let error = store.transcriptErrors[sessionId] {
                    ContentUnavailableView {
                        Label("Couldn't Load Messages", systemImage: "exclamationmark.bubble")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") { store.open(sessionId) }
                            .buttonStyle(.borderedProminent)
                    }
                } else if store.loadingTranscripts.contains(sessionId) {
                    ProgressView()
                }
            }
        }
        // Drop a screenshot thumbnail, a photo or a file anywhere on the conversation to attach it.
        .dropDestination(for: DroppedAttachment.self) { items, _ in
            AttachmentLoader.add(items.map(\.draft), to: $attachments, store: store)
            return !items.isEmpty
        } isTargeted: { targeted in
            withAnimation(.smooth(duration: 0.2)) { dropTargeted = targeted }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color.userBubble, style: StrokeStyle(lineWidth: 2.5, dash: [10, 6]))
                    .background(Color.userBubble.opacity(0.08), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay {
                        Label("Drop to attach", systemImage: "paperclip")
                            .font(.headline)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .glassEffect()
                    }
                    .padding(10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .environment(\.beginMessageSelection) { id in withAnimation(.smooth) { selected = [id] } }
        .onAppear { store.open(sessionId) }
        .onChange(of: store.draftSeeds[sessionId], initial: true) { _, seed in
            // Text restored by "Restore to Here" or carried into a fork.
            guard let seed else { return }
            draft = seed
            store.draftSeeds[sessionId] = nil
        }
        .onDisappear { store.close(sessionId) }
    }

    @ViewBuilder
    private func rowContent(_ row: ChatRow, previous: ChatRow?, next: ChatRow?, working: Bool) -> some View {
        switch row {
        case .item(.userText(let user)) where user.isPending && queue.contains { $0.localId == user.localId }:
            if let queued = queue.first(where: { $0.localId == user.localId }) {
                PendingBubble(message: queued, sessionId: sessionId, working: working)
            }
        case .item(let item):
            ChatItemView(item: item, sessionId: sessionId, tail: Side(row) != next.map(Side.init) || working && next == nil)
        case .work(let steps, _, let inProgress):
            // Duration runs from your message to the turn's final answer.
            WorkRow(steps: steps, inProgress: inProgress,
                    startedAt: previous.flatMap { if case .item(.userText) = $0 { $0.createdAt } else { nil } },
                    endedAt: next.flatMap { Side($0) == .agent ? $0.createdAt : nil },
                    sessionId: sessionId)
        case .tools(let tools, _):
            ToolGroupRow(tools: tools, sessionId: sessionId)
        }
    }

    // MARK: Selection

    private func selectableItems(working: Bool) -> [ChatItem] {
        ChatRow.rows(from: items, working: working).compactMap { row in
            if case .item(let item) = row, MessageSelection.isSelectable(item) { return item }
            return nil
        }
    }

    private func selectedText(working: Bool) -> String {
        let chosen = selectableItems(working: working).filter { selected?.contains($0.id) == true }
        let agentName = session?.agentId.flatMap { Agent.displayNames[$0] } ?? String(localized: "Agent")
        return MessageSelection.clipboardText(chosen, agentName: agentName)
    }

    /// Scrolls to a concrete view at the end of the transcript, after the new bubble has been laid
    /// out. Scrolling to an *edge* while a LazyVStack is still growing can land on an unrealized
    /// region and leave the viewport blank until the user scrolls; a concrete id forces it to render.
    private func scrollToBottom(animated: Bool = true) {
        Task { @MainActor in
            await Task.yield()
            defer { followScheduled = false }
            // A chat that fits on screen already rests on its end (bottom-anchored); an id-anchored
            // scroll would push the last message under the composer.
            if lastGeometry?.fitsOnScreen == true { return }
            if animated {
                withAnimation(.smooth(duration: 0.3)) { scrollPosition.scrollTo(id: Self.bottomAnchor, anchor: .bottom) }
            } else {
                scrollPosition.scrollTo(id: Self.bottomAnchor, anchor: .bottom)
            }
        }
    }

    private static func chatGeometry(_ g: ScrollGeometry) -> ChatScroll.Geometry {
        ChatScroll.Geometry(offsetY: g.contentOffset.y, containerHeight: g.containerSize.height,
                            contentHeight: g.contentSize.height, topInset: g.contentInsets.top)
    }

    private static let bottomAnchor = "chat-bottom"

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .principal) {
            if let session {
                VStack(spacing: 1) {
                    Text(session.title)
                        .font(.headline)
                        .lineLimit(1)
                    if let folder = session.displayPath {
                        Text(folder)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }
        }
        #endif
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if let session {
                    if let agent = session.agentId, let name = Agent.displayNames[agent] {
                        Text(name)
                    }
                    if let path = session.displayPath {
                        Label(path, systemImage: "folder")
                    }
                    if let host = session.host {
                        Label(host, systemImage: "desktopcomputer")
                    }
                    let pinned = store.pins.pinned(sessionId: sessionId)
                    if !pinned.isEmpty {
                        Menu("Pinned Messages", systemImage: "pin") {
                            ForEach(pinned, id: \.seq) { pin in
                                if let item = items.first(where: { $0.seq == pin.seq }) {
                                    Button(item.previewText) {
                                        pinnedToEnd = false
                                        withAnimation(.smooth) { scrollPosition.scrollTo(id: item.id, anchor: .center) }
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Stop Agent", systemImage: "stop.circle") { Task { await store.abort(sessionId) } }
                    if session.active {
                        Button("Stop Session", systemImage: "power", role: .destructive) { store.requestStop(sessionId) }
                    }
                    Button("Archive", systemImage: "archivebox") { Task { await store.archive(sessionId) } }
                }
            } label: {
                Label("Details", systemImage: "info.circle")
            }
        }
    }
}

/// Which side of the conversation an item sits on, for grouping and bubble tails.
private enum Side: Equatable {
    case user, agent, center
    init(_ row: ChatRow) {
        switch row {
        case .item(.userText): self = .user
        case .item(.agentText), .item(.toolCall), .work, .tools: self = .agent
        case .item(.event): self = .center
        }
    }
}

private extension ChatItem {
    var seq: Int? {
        switch self {
        case .userText(let message): message.seq
        case .agentText(let message): message.seq
        default: nil
        }
    }

    var previewText: String {
        let text: String = switch self {
        case .userText(let message): message.text
        case .agentText(let message): message.text
        case .toolCall(let tool): tool.name
        case .event(let event): event.kind
        }
        return String(text.prefix(60))
    }
}

/// Replaces the composer while selecting messages (RN `TranscriptSelectionToolbar`).
private struct SelectionBar: View {
    let count: Int
    let onCopy: () -> Void
    let onSend: () -> Void
    let onSelectAll: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button("Cancel", action: onCancel)
                .buttonStyle(.glass)
            Spacer(minLength: 0)
            Text(count == 1 ? String(localized: "1 selected") : String(localized: "\(count) selected"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Menu {
                Button("Select All", systemImage: "checkmark.circle", action: onSelectAll)
                Button("Send to Session…", systemImage: "arrowshape.turn.up.right", action: onSend)
                    .disabled(count == 0)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            Button("Copy", action: onCopy)
                .buttonStyle(.glassProminent)
                .disabled(count == 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Pick another session to send the selected messages to.
private struct SessionPicker: View {
    let excluding: String
    let onPick: (String) -> Void
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(store.sessionList.filter { $0.id != excluding }) { session in
                Button {
                    dismiss()
                    onPick(session.id)
                } label: {
                    HStack(spacing: 12) {
                        SessionAvatar(session: session, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title).foregroundStyle(.primary).lineLimit(1)
                            if let path = session.displayPath {
                                Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Send to Session")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

import HappierKit
import SwiftUI

struct ChatView: View {
    let sessionId: String
    @Environment(HappierStore.self) private var store
    @State private var draft = ""
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    /// Selected transcript item ids; nil when not in selection mode.
    @State private var selected: Set<String>?
    @State private var choosingDestination = false

    private var session: Session? { store.sessions[sessionId] }
    private var queue: [PendingMessage] { store.pendingQueues[sessionId] ?? [] }

    /// Transcript items minus optimistic bubbles the server queue now owns (same localId).
    private var items: [ChatItem] {
        let all = store.transcripts[sessionId]?.items ?? []
        let queued = Set(queue.map(\.localId))
        guard !queued.isEmpty else { return all }
        return all.filter { item in
            if case .userText(let message) = item, message.isPending, let localId = message.localId { return !queued.contains(localId) }
            return true
        }
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
                    ForEach(queue) { message in
                        PendingBubble(message: message, sessionId: sessionId, working: working)
                            .padding(.top, 8)
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
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .animation(.smooth(duration: 0.3), value: items.count)
                .animation(.smooth(duration: 0.3), value: queue.map(\.localId))
                .animation(.smooth(duration: 0.3), value: working)
            }
            .scrollPosition($scrollPosition)
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .onChange(of: items.last?.id) { _, _ in
                // Your own message just landed (optimistic bubble): follow it to the bottom.
                if case .userText(let message)? = items.last, message.isPending { scrollToBottom() }
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
                Composer(sessionId: sessionId, text: $draft, working: working) { attachments in
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty || !attachments.isEmpty else { return }
                    draft = ""
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
    private func scrollToBottom() {
        Task { @MainActor in
            await Task.yield()
            withAnimation(.smooth(duration: 0.3)) { scrollPosition.scrollTo(id: Self.bottomAnchor, anchor: .bottom) }
        }
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
                                        withAnimation(.smooth) { scrollPosition.scrollTo(id: item.id, anchor: .center) }
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Stop Agent", systemImage: "stop.circle") { Task { await store.abort(sessionId) } }
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

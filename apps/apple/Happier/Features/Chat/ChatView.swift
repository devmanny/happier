import HappierKit
import SwiftUI

struct ChatView: View {
    let sessionId: String
    @Environment(HappierStore.self) private var store
    @State private var draft = ""
    @State private var scrollPosition = ScrollPosition(edge: .bottom)

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
                    let rows = ChatRow.rows(from: items)
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
                        Group {
                            switch row {
                            case .item(let item):
                                ChatItemView(item: item, sessionId: sessionId, tail: Side(row) != next.map(Side.init) || working && next == nil)
                            case .tools(let tools, _):
                                ToolGroupRow(tools: tools, sessionId: sessionId)
                            }
                        }
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
                    if working {
                        HStack {
                            TypingIndicator()
                            Spacer()
                        }
                        .padding(.top, 8)
                        .transition(.scale(scale: 0.6, anchor: .bottomLeading).combined(with: .opacity))
                    }
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
        .onAppear { store.open(sessionId) }
        .onChange(of: store.draftSeeds[sessionId], initial: true) { _, seed in
            // Text restored by "Restore to Here" or carried into a fork.
            guard let seed else { return }
            draft = seed
            store.draftSeeds[sessionId] = nil
        }
        .onDisappear { store.close(sessionId) }
    }

    private func scrollToBottom() {
        withAnimation(.smooth(duration: 0.3)) { scrollPosition.scrollTo(edge: .bottom) }
    }

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
        case .item(.agentText), .item(.toolCall), .tools: self = .agent
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

import HappierKit
import os
import SwiftUI

struct ChatView: View {
    let sessionId: String
    @Environment(HappierStore.self) private var store
    @Environment(\.tasksPanelAvailable) private var tasksPanelAvailable

    var body: some View {
        SessionChatHost(sessionId: sessionId, details: details).equatable()
    }

    /// What the ⓘ menu shows, as plain values.
    private var details: SessionDetailsMenu.Details {
        let session = store.sessions[sessionId]
        let items = store.transcripts[sessionId]?.items ?? []
        let pins = store.pins.pinned(sessionId: sessionId).compactMap { pin -> SessionDetailsMenu.Pin? in
            items.first { $0.seq == pin.seq }.map { SessionDetailsMenu.Pin(itemId: $0.id, title: $0.previewText) }
        }
        return SessionDetailsMenu.Details(
            sessionId: sessionId,
            agentName: session?.agentId.flatMap { Agent.displayNames[$0] },
            vendorSessionId: session?.vendorSessionId,
            hasBackground: store.transcripts[sessionId]?.subagents.isEmpty == false || store.delegatedRuns[sessionId]?.isEmpty == false
                || (session?.runtimeActivityRevision ?? 0) > 0,
            pins: pins, active: session.map { $0.status() != .offline } ?? false, archived: session?.archivedAt != nil, loaded: session != nil,
            nested: session?.parentSessionId.map { store.sessions.keys.contains($0) } ?? false,
            deletable: session?.canDelete ?? false,
            folderPath: session?.path,
            folderColor: store.folderColor(of: session),
            // Where there's no Tasks panel (iPhone), the session's own tasks are one tap away.
            sessionTasks: tasksPanelAvailable ? nil : sessionTaskCount,
            // iPhone: the bell lives in the ⓘ menu so the bar keeps its shape; iPad and Mac keep it in the bar.
            bellInMenu: !tasksPanelAvailable,
            notificationsMuted: session?.notificationsMuted == true)
    }

    /// Open tasks linked to this session, or nil when none is linked at all.
    private var sessionTaskCount: Int? {
        let linked = store.tasks.filter { $0.isLinked(to: sessionId) }
        return linked.isEmpty ? nil : linked.filter(\.isOpen).count
    }

}

/// The chrome changes when its displayed menu values change. The conversation and usage retain
/// their own subscriptions, so streaming doesn't regenerate a menu that is tracking a touch.
private struct SessionChatHost: View, Equatable {
    let sessionId: String
    let details: SessionDetailsMenu.Details
    @State private var showActivity = false
    @State private var finding = false
    @State private var pinnedToEnd = true
    @State private var scrollPosition = ScrollPosition(idType: String.self)

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sessionId == rhs.sessionId && lhs.details == rhs.details
    }

    var body: some View {
        ChatConversationView(sessionId: sessionId, showActivity: $showActivity, scrollPosition: $scrollPosition,
                             pinnedToEnd: $pinnedToEnd, finding: $finding)
            .modifier(SessionToolbar(sessionId: sessionId, details: details, showActivity: $showActivity,
                                     finding: $finding, pinnedToEnd: $pinnedToEnd, scrollPosition: $scrollPosition))
    }
}

private struct ChatConversationView: View {
    let sessionId: String
    @Environment(HappierStore.self) private var store
    /// Bumped only when "working" flips with time alone (see `body`).
    @State private var statusClock = 0
    /// The rows' actions: one object for the conversation's life, so the environment its rows read
    /// doesn't change on every update (see `ChatRowActions`).
    @State private var rowActions = ChatRowActions()
    @State private var draft = ""
    /// The synced draft text the composer last took up or saw, to tell your own edits from it.
    @State private var lastSyncedDraft = ""
    @Binding var showActivity: Bool
    /// The message open for selecting its text ("Select Text"), and where it is on screen.
    @State private var textSelectingId: String?
    @State private var textSelectingFrame = CGRect.zero
    /// A reply suggestion being dragged: dropped on the conversation, it goes to the composer.
    @State private var draggedReply: String?
    @State private var attachments: [AttachmentDraft] = []
    @State private var dropTargeted = false
    @Binding var scrollPosition: ScrollPosition
    /// Follow the newest message until the user drags away from it (`ChatScroll`).
    @Binding var pinnedToEnd: Bool
    /// Where the scroll is, written every frame: kept out of the view's state so scrolling
    /// doesn't redraw the conversation. Only what's shown from it is state (`showsJump`).
    @State private var scrollState = ChatScrollState()
    @State private var showsJump = false
    /// Rows last seen on screen, and when a blank viewport was last put right.
    @State private var lastBlankRepair = Date.distantPast
    /// How many of the newest rows are drawn (`ChatWindow`).
    @State private var windowLimit = ChatWindow.initial
    @State private var revealingOlder = false
    /// Search inside this conversation.
    @Binding var finding: Bool
    @State private var findQuery = ""
    @State private var findCurrentId: String?
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
                                          createdAt: message.createdAt, localId: message.localId, isPending: true,
                                          files: message.files, sessionMessageOrigin: message.sessionMessageOrigin)))
        }
        return all
    }

    var body: some View {
        // "Working" goes stale with time (no signal for a while); `statusClock` redraws only when
        // that flips, instead of rebuilding the whole conversation every 15 s.
        let _ = statusClock
        let working = session?.status(at: .now) == .working
        Group {
        ScrollView {
            // Drawn in full, not lazily: a lazy stack moved by the app's own scrolls (opening,
            // following the end) could rest on rows it had only estimated and stay blank.
            // `ChatWindow` keeps how many rows are drawn bounded.
            VStack(spacing: 2) {
                let allRows = ChatRow.rows(from: items, working: working)
                let rows = Array(ChatWindow.visible(allRows, limit: windowLimit))
                if rows.count < allRows.count || store.hasOlderMessages[sessionId] == true {
                    // One step back in history each time it comes into view.
                    HappierSpinner()
                        .padding()
                        .onScrollVisibilityChange(threshold: 0.01) { visible in
                            if visible { Task { await revealOlder() } }
                        }
                }
                // Straight in the stack: the rows must be the scroll target layout's own children.
                // Wrapped in a view of their own (even one that only skipped redraws) the scroll
                // stopped seeing them, kept its position on the bottom anchor and pulled the
                // reader back there on every redraw.
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, _ in
                    transcriptRow(rows, at: index, working: working)
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
        .simultaneousGesture(closeTextSelection)
        .contentMargins(.horizontal, 14, for: .scrollContent)
        .contentMargins(.vertical, 10, for: .scrollContent)
        .scrollPosition($scrollPosition)
        // Opens on the newest message. Growing content doesn't pull the view down (that kept a
        // reader scrolled up from reading while the agent worked); a pinned chat follows the
        // end on its own (`onScrollGeometryChange`).
        .defaultScrollAnchor(.bottom)
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
            scrollState.geometry = new
            let jump = ChatScroll.showsJumpToLatest(new)
            if jump != showsJump { showsJump = jump }
            // Rows measured at their real height, typing dots, a streamed reply or a taller
            // composer moved the end: a pinned chat goes back to it.
            guard ChatScroll.shouldFollow(pinned: pinnedToEnd, geometry: new), !scrollState.followScheduled else { return }
            scrollState.followScheduled = true
            scrollToBottom(animated: false)
        }
        .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { visible in
            // A lazy stack can settle on a stretch it hasn't drawn yet (a jump while rows were
            // still being measured, mostly on the Mac with a long, busy transcript) and stay
            // blank until the next scroll. Seeing no row at all, put the reader back on drawn ones.
            guard visible.isEmpty else {
                scrollState.visibleIds = visible
                return
            }
            guard !items.isEmpty, Date.now.timeIntervalSince(lastBlankRepair) > 0.5 else { return }
            lastBlankRepair = .now
            Self.scrollLog.notice("blank transcript viewport; scrolling back onto rows")
            if pinnedToEnd {
                scrollPosition.scrollTo(id: Self.bottomAnchor, anchor: .bottom)
            } else if let row = scrollState.visibleIds.first {
                scrollPosition.scrollTo(id: row, anchor: .top)
            } else {
                scrollPosition.scrollTo(id: Self.bottomAnchor, anchor: .bottom)
            }
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
        // Scrolled up into the history: a button back to the newest message.
        .overlay(alignment: .bottom) {
            if showsJump {
                Button {
                    AppHaptics.light()
                    pinnedToEnd = true
                    scrollToBottom()
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.body.weight(.semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)
                .glassHover()
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .padding(.bottom, 10)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .accessibilityLabel(Text("Jump to latest"))
            }
        }
        .animation(.smooth(duration: 0.2), value: showsJump)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let selected {
                SelectionBar(count: selected.count) {
                    MessageClipboard.copy(selectedText(working: working))
                    AppHaptics.success()
                    withAnimation(.smooth) { self.selected = nil }
                } onSend: {
                    AppHaptics.light()
                    choosingDestination = true
                } onSelectAll: {
                    AppHaptics.selection()
                    self.selected = Set(selectableItems(working: working).map(\.id))
                } onCancel: {
                    AppHaptics.light()
                    withAnimation(.smooth) { self.selected = nil }
                }
                .sheet(isPresented: $choosingDestination) {
                    SessionPickerSheet(title: Text("Send to Session"), offers: { $0.id != sessionId }) { destination in
                        let text = selectedText(working: working)
                        withAnimation(.smooth) { self.selected = nil }
                        Task {
                            await store.send(text, to: destination.id)
                            store.openRequest = destination.id
                        }
                    }
                }
            } else {
            VStack(spacing: 0) {
            if MessageSpeaker.shared.speakingText != nil {
                SpeechControls()
                    .padding(.top, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Composer(sessionId: sessionId, text: $draft, attachments: $attachments, working: working) { attachments in
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty || !attachments.isEmpty else { return }
                draft = ""
                pinnedToEnd = true
                scrollToBottom()
                Task { await store.send(text, attachments: attachments, to: sessionId) }
            } onStop: {
                Task { await store.abort(sessionId) }
            } onShowActivity: {
                showActivity = true
            }
            }
            .animation(.smooth(duration: 0.25), value: MessageSpeaker.shared.speakingText != nil)
            }
        }
    }
        .safeAreaInset(edge: .top, spacing: 0) {
            if finding {
                let matches = TranscriptSearch.matches(in: items, query: findQuery)
                FindBar(query: $findQuery, matches: matches, currentId: $findCurrentId,
                        searchingOlder: !findQuery.isEmpty && store.hasOlderMessages[sessionId] == true) {
                    withAnimation(.smooth(duration: 0.2)) {
                        finding = false
                        findQuery = ""
                        findCurrentId = nil
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: findCurrentId) { _, id in
            guard let id else { return }
            pinnedToEnd = false
            // An older match may lie outside the drawn window: widen it first, then scroll.
            windowLimit = ChatWindow.limit(including: id, in: ChatRow.rows(from: items, working: false), current: windowLimit)
            Task { @MainActor in
                await Task.yield()
                withAnimation(.smooth) { scrollPosition.scrollTo(id: id, anchor: .center) }
            }
        }
        .task(id: finding && !findQuery.isEmpty) {
            // The transcript is end-to-end encrypted: searching it means having it here, all of it.
            guard finding, !findQuery.isEmpty else { return }
            while store.hasOlderMessages[sessionId] == true, !Task.isCancelled {
                let before = store.transcripts[sessionId]?.minSeq
                await store.loadOlder(sessionId)
                if store.transcripts[sessionId]?.minSeq == before { break }
            }
        }
        .task(id: sessionId) {
            // "Working" ends by itself once the session stops signalling: check every 15 s and
            // redraw only if it flipped.
            var shown = session?.status(at: .now) == .working
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                let now = session?.status(at: .now) == .working
                if now != shown { statusClock &+= 1 }
                shown = now
            }
        }
        .task(id: sessionId) {
            // The provider's limits, read again as often as the daemon refreshes them.
            while !Task.isCancelled {
                await store.refreshProviderUsage(sessionId)
                let interval = max(30, store.providerUsage[sessionId]?.staleAfter ?? 300)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle(session?.title ?? "")
        .navigationSubtitle(session?.displayPath ?? "")
        .overlay {
            if items.isEmpty {
                if let error = store.transcriptErrors[sessionId] {
                    ContentUnavailableView {
                        Label("Couldn't Load Messages", systemImage: "exclamationmark.bubble")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { store.open(sessionId) }
                            .buttonStyle(.glassProminent)
                            .glassHover()
                    }
                } else if store.loadingTranscripts.contains(sessionId) {
                    HappierSpinner(size: HappierSpinner.hero)
                }
            }
        }
        // Drop a screenshot thumbnail, a photo or a file anywhere on the conversation to attach it.
        .dropDestination(for: DroppedAttachment.self) { items, _ in
            if let reply = draggedReply {
                draggedReply = nil
                appendToDraft(reply)
                return true
            }
            // A session row dragged over from the list isn't a file to attach.
            let files = items.map(\.draft).filter { !SessionDrag.isPayload($0.data) }
            AttachmentLoader.add(files, to: $attachments, store: store)
            return !files.isEmpty
        } isTargeted: { targeted in
            withAnimation(.smooth(duration: 0.2)) { dropTargeted = targeted && draggedReply == nil }
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
        .environment(\.chatRowActions, rowActions)
        // Your bubbles in the project folder's color, when it has one.
        .environment(\.userBubbleColor, store.folderColor(of: session)?.deep ?? .userBubble)
        .environment(\.textSelectingId, textSelectingId)
        .modifier(SessionFilePreview(sessionId: sessionId))
        .onAppear {
            connectRowActions()
            store.open(sessionId)
            // What you were typing here before switching away, synced or not.
            if draft.isEmpty, let local = store.localDraft(sessionId) { draft = local }
        }
        .onChange(of: store.syncedDrafts[sessionId], initial: true) { _, synced in
            // A draft from another device fills the composer unless you've typed over it here.
            guard let synced else { return }
            if draft == lastSyncedDraft || draft.isEmpty { draft = synced.text }
            lastSyncedDraft = synced.text
        }
        .onChange(of: draft) { _, text in
            store.draftChanged(sessionId, text: text)
            // Dropped straight into the field (the text view took it): the drag is over.
            draggedReply = nil
        }
        .onChange(of: store.draftSeeds[sessionId], initial: true) { _, seed in
            // Text restored by "Restore to Here" or carried into a fork.
            guard let seed else { return }
            draft = seed
            store.draftSeeds[sessionId] = nil
        }
        .onDisappear { store.close(sessionId) }
    }

    /// One transcript row with its date separator above and its time below, as its neighbours call for.
    @ViewBuilder
    private func transcriptRow(_ rows: [ChatRow], at index: Int, working: Bool) -> some View {
        let row = rows[index]
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
        .background {
            if finding, row.id == findCurrentId {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.yellow.opacity(0.28))
                    .padding(-4)
            }
        }
        .contentShape(Rectangle())
        // Row taps toggle selection only in selection mode; otherwise the bubble's own controls win.
        .gesture(TapGesture().onEnded {
            guard case .item(let item) = row, MessageSelection.isSelectable(item) else { return }
            if selected != nil { AppHaptics.selection() }
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
            // Duration runs from the message before these steps to the agent's next message.
            WorkRow(steps: steps, inProgress: inProgress,
                    startedAt: previous.flatMap { if case .item = $0 { $0.createdAt } else { nil } },
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
    private static let scrollLog = Logger(subsystem: "dev.happier.apple", category: "chat-scroll")

    /// A tap outside the message being selected puts it back to normal.
    private var closeTextSelection: some Gesture {
        SpatialTapGesture(coordinateSpace: .global).onEnded { tap in
            guard textSelectingId != nil, !textSelectingFrame.contains(tap.location) else { return }
            withAnimation(.smooth(duration: 0.2)) { textSelectingId = nil }
        }
    }

    /// Adds text to what's being written, a space apart.
    /// What the rows' actions do here; set once (they write this view's state, which outlives copies).
    private func connectRowActions() {
        rowActions.beginMessageSelection = { id in
            AppHaptics.selection()
            withAnimation(.smooth) { selected = [id] }
        }
        rowActions.editInComposer = { text in appendToDraft(text) }
        rowActions.beginTextSelection = { id in
            AppHaptics.light()
            withAnimation(.smooth(duration: 0.2)) { textSelectingId = id }
        }
        rowActions.reportTextSelectionFrame = { frame in textSelectingFrame = frame }
        rowActions.replyDragStarted = { text in draggedReply = text }
    }

    private func appendToDraft(_ text: String) {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = text
        } else {
            draft += (draft.hasSuffix(" ") || draft.hasSuffix("\n") ? "" : " ") + text
        }
    }

    private func scrollToBottom(animated: Bool = true) {
        Task { @MainActor in
            await Task.yield()
            defer { scrollState.followScheduled = false }
            // A chat that fits on screen already rests on its end (bottom-anchored); an id-anchored
            // scroll would push the last message under the composer.
            if scrollState.geometry?.fitsOnScreen == true { return }
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

    /// One step back in history: more of what is already loaded, or the page before it. The
    /// oldest message drawn stays in place and the new rows land above it, out of view, so the
    /// next step waits until you scroll up to the loader again. Only while the transcript doesn't
    /// fill the screen (a page of agent steps folds into one line) do steps follow on their own.
    private func revealOlder() async {
        guard !revealingOlder else { return }
        revealingOlder = true
        defer { revealingOlder = false }
        for _ in 0..<20 {
            let filled = scrollState.geometry?.fitsOnScreen == false
            let allRows = ChatRow.rows(from: items, working: false)
            let anchor = ChatWindow.visible(allRows, limit: windowLimit).first { if case .item = $0 { true } else { false } }?.id
            if allRows.count > windowLimit {
                windowLimit += ChatWindow.step
            } else if store.hasOlderMessages[sessionId] == true {
                await store.loadOlder(sessionId)
                windowLimit = ChatRow.rows(from: items, working: false).count
            } else {
                return
            }
            if filled {
                if let anchor {
                    await Task.yield()
                    scrollPosition.scrollTo(id: anchor, anchor: .top)
                }
                return
            }
            // Let the new rows lay out before checking whether the screen is full now.
            try? await Task.sleep(for: .milliseconds(80))
        }
    }


}

/// The toolbar and its presentations own a separate update boundary from the live transcript.
/// Usage observes the store inside its own toolbar content; a token update must not replace the
/// native menu's actions while UIKit is tracking a touch.
private struct SessionToolbar: ViewModifier {
    let sessionId: String
    let details: SessionDetailsMenu.Details
    /// The tasks linked to this session (iPhone, from the ⓘ menu).
    @State private var showSessionTasks = false
    @Binding var showActivity: Bool
    @Binding var finding: Bool
    @Binding var pinnedToEnd: Bool
    @Binding var scrollPosition: ScrollPosition
    @Environment(HappierStore.self) private var store
    @State private var showInfo = false
    @State private var renaming: Session?
    @State private var showBrowser = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(BrowserModel.self) private var browser

    func body(content: Content) -> some View {
        content
            .toolbar {
                #if os(macOS)
                ToolbarItem(placement: .primaryAction) {
                    Button("Search Here", systemImage: "magnifyingglass") { startFinding() }
                        .keyboardShortcut("f", modifiers: .command)
                }
                #endif
                // Once the agent has used the browser, its tab is one tap away (✨ while it works).
                if browser.hasTabs(for: sessionId) {
                    ToolbarItem(placement: .primaryAction) {
                        SessionBrowserButton(sessionId: sessionId) { openBrowser() }
                    }
                }
                ToolbarItem(placement: .primaryAction) { AutoReadButton(sessionId: sessionId) }
                if !details.bellInMenu {
                    ToolbarItem(placement: .primaryAction) { SessionBellButton(sessionId: sessionId) }
                } else if let open = details.sessionTasks {
                    // iPhone: the session's own tasks, where the bell was; only when it has linked tasks.
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            perform(.sessionTasks)
                        } label: {
                            Label("Session Tasks", systemImage: "checklist")
                        }
                        .badge(open)
                        .accessibilityLabel(open == 0 ? "Session tasks" : "Session tasks, \(open) open")
                    }
                }
                SessionUsageToolbar(sessionId: sessionId)
                ToolbarItem(placement: .primaryAction) {
                    SessionDetailsMenu(details: details, perform: perform).equatable()
                }
            }
            .modifier(RenameSessionAlert(session: $renaming))
            .sheet(isPresented: $showSessionTasks) {
                TasksView(openSessionId: sessionId, onlyThisSession: true)
            }
            .sheet(isPresented: $showActivity) {
                AgentActivitySheet(sessionId: sessionId)
                    #if os(macOS)
                    .frame(minWidth: 480, minHeight: 520)
                    #endif
            }
            .sheet(isPresented: $showBrowser) {
                BrowserView(inSheet: true)
            }
            .sheet(isPresented: $showInfo) {
                SessionInfoView(sessionId: sessionId)
                    #if os(macOS)
                    .frame(minWidth: 480, minHeight: 560)
                    #endif
            }
    }

    private func startFinding() {
        AppHaptics.light()
        withAnimation(.smooth(duration: 0.2)) { finding = true }
    }

    /// The browser on this session's tab: its own window on the Mac and iPad, a sheet on the iPhone.
    private func openBrowser() {
        AppHaptics.light()
        browser.showTab(for: sessionId)
        if supportsMultipleWindows {
            openWindow(id: BrowserWindow.id, value: BrowserWindow.value)
        } else {
            showBrowser = true
        }
    }

    private func perform(_ action: SessionDetailsMenu.Action) {
        switch action {
        case .info: AppHaptics.light(); showInfo = true
        case .search: startFinding()
        case .background: AppHaptics.light(); showActivity = true
        case .sessionTasks: AppHaptics.light(); showSessionTasks = true
        case .toggleNotifications:
            AppHaptics.selection()
            let muted = store.sessions[sessionId]?.notificationsMuted == true
            Task { await store.setNotificationsMuted(!muted, in: sessionId) }
        case .openInWindow: openWindow(id: SessionWindow.id, value: sessionId)
        case .browser: openBrowser()
        case .folderColor(let color):
            AppHaptics.light()
            if let path = store.sessions[sessionId]?.path { store.setFolderColor(color, forPath: path) }
        case .rename: AppHaptics.light(); renaming = store.sessions[sessionId]
        case .moveToTopLevel:
            AppHaptics.confirm()
            Task { await store.nest(sessionId, under: nil) }
        case .jump(let itemId):
            AppHaptics.selection()
            pinnedToEnd = false
            withAnimation(.smooth) { scrollPosition.scrollTo(id: itemId, anchor: .center) }
        case .stopAgent:
            AppHaptics.warning()
            Task { await store.abort(sessionId) }
        case .stopSession: AppHaptics.warning(); store.requestStop(sessionId)
        case .archive:
            AppHaptics.confirm()
            Task { await store.archive(sessionId) }
        case .unarchive:
            AppHaptics.confirm()
            Task { await store.unarchive(sessionId) }
        case .delete:
            AppHaptics.warning()
            if let session = store.sessions[sessionId] { store.requestDelete(session) }
        }
    }
}

/// The session's tab in the integrated browser; it pulses while the agent is using it.
private struct SessionBrowserButton: View {
    let sessionId: String
    let action: () -> Void
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        // The pulse animates by itself; the view updates once more, when the agent's use ends
        // (it ticked every second whenever the session had a tab).
        let activeUntil = browser.tabs.filter { $0.sessionId == sessionId }.compactMap(\.agentActiveUntil).max() ?? .distantPast
        TimelineView(.explicit(activeUntil > .now ? [activeUntil] : [])) { context in
            let working = activeUntil > context.date
            Button(action: action) {
                Label("Browser", systemImage: "safari")
                    .symbolEffect(.pulse, isActive: working)
            }
            .help(working ? "The agent is using the browser" : "Browser")
        }
    }
}

private struct SessionUsageToolbar: ToolbarContent {
    let sessionId: String
    @Environment(HappierStore.self) private var store

    var body: some ToolbarContent {
        let session = store.sessions[sessionId]
        let usage = store.providerUsage[sessionId] ?? session?.lastRuntimeIssue.flatMap(ProviderUsage.init(runtimeIssue:))
        let context = store.transcripts[sessionId]?.contextUsage
        let controls = store.controls(for: sessionId)
        let modelId = controls.flatMap { $0.selectedModelId != "default" ? $0.selectedModelId : $0.appliedModelId }
        if session != nil {
            ToolbarItem(placement: .primaryAction) {
                SessionUsageButton(sessionId: sessionId, context: context,
                                   window: context.flatMap { controls?.contextWindow(for: $0) },
                                   usage: usage, modelId: modelId,
                                   agentName: session?.agentId.flatMap { Agent.displayNames[$0] })
            }
        }
    }
}

/// Which side of the conversation an item sits on, for grouping and bubble tails.
private enum Side: Equatable {
    case user, agent, center
    init(_ row: ChatRow) {
        switch row {
        case .item(.userText(let message)): self = message.sessionNotice == nil && message.sessionMessageOrigin == nil ? .user : .center
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
            Button("Cancel", role: .cancel, action: onCancel)
                .buttonStyle(.glass)
                .glassHover()
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
            .glassHover()
            .buttonBorderShape(.circle)
            Button("Copy", action: onCopy)
                .buttonStyle(.glassProminent)
                .glassHover()
                .disabled(count == 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Search inside the open conversation: a field, how many messages match, and arrows to walk
/// them from the newest up; the message in view is highlighted in the transcript. Laid out like
/// the drawer's search: the glass field, and a glass X beside it to put it away.
private struct FindBar: View {
    @Binding var query: String
    /// Matching message ids, oldest first.
    let matches: [String]
    @Binding var currentId: String?
    let searchingOlder: Bool
    let onDone: () -> Void
    @FocusState private var focused: Bool

    private var index: Int? { currentId.flatMap { matches.firstIndex(of: $0) } }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Here", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit { step(-1) }
                if searchingOlder {
                    HappierSpinner(size: HappierSpinner.mini)
                        .accessibilityLabel(Text("Searching older messages"))
                }
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(position)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button { step(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled((index ?? 0) <= 0)
                    .accessibilityLabel(Text("Older match"))
                Button { step(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index.map { $0 >= matches.count - 1 } ?? true)
                    .accessibilityLabel(Text("Newer match"))
            }
            .buttonStyle(.pressable)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .glassEffect(.regular.interactive(), in: Capsule())
            Button { AppHaptics.light(); onDone() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.medium))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .glassHover()
            .buttonBorderShape(.circle)
            .accessibilityLabel(Text("Close Search"))
        }
        .onAppear { focused = true }
        .onChange(of: matches) { _, matches in
            // A new search starts at the newest match; older pages arriving keep the one in view.
            if currentId.map(matches.contains) != true { currentId = matches.last }
        }
        #if os(macOS)
        .onExitCommand(perform: onDone)
        #endif
    }

    /// "1 of 12" counts from the newest.
    private var position: String {
        guard !matches.isEmpty else { return String(localized: "No results") }
        let fromNewest = matches.count - (index ?? matches.count - 1)
        return String(localized: "\(fromNewest) of \(matches.count)")
    }

    private func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        let next = min(max((index ?? matches.count - 1) + delta, 0), matches.count - 1)
        if currentId != matches[next] { AppHaptics.selection() }
        currentId = matches[next]
    }
}

/// The ⓘ menu, grouped by navigation, session actions, then stop/archive. Compared by its
/// displayed values so unrelated session updates don't rebuild it while it is open.
private struct SessionDetailsMenu: View, Equatable {
    struct Pin: Equatable {
        let itemId: String
        let title: String
    }

    struct Details: Equatable {
        let sessionId: String
        let agentName: String?
        let vendorSessionId: String?
        let hasBackground: Bool
        let pins: [Pin]
        let active: Bool
        let archived: Bool
        let loaded: Bool
        let nested: Bool
        let deletable: Bool
        let folderPath: String?
        let folderColor: AccountSettings.FolderColor?
        /// Open tasks linked to this session; nil hides the entry (none linked, or a Tasks panel exists).
        var sessionTasks: Int? = nil
        var bellInMenu = false
        var notificationsMuted = false
    }

    enum Action {
        case info, search, openInWindow, browser, rename, moveToTopLevel, background, jump(String), stopAgent, stopSession, archive, unarchive, delete, sessionTasks, toggleNotifications
        case folderColor(AccountSettings.FolderColor?)
    }

    let details: Details
    let perform: (Action) -> Void
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.inSessionWindow) private var inSessionWindow

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.details == rhs.details }

    var body: some View {
        Menu {
            if supportsMultipleWindows && !inSessionWindow {
                Button("Open in New Window", systemImage: "macwindow.badge.plus") { perform(.openInWindow) }
            }
            // Find your way around the conversation.
            Section {
                Button("Search Here", systemImage: "magnifyingglass") { perform(.search) }
                if !details.pins.isEmpty {
                    Menu("Pinned Messages", systemImage: "pin") {
                        ForEach(details.pins, id: \.itemId) { pin in
                            Button(pin.title) { perform(.jump(pin.itemId)) }
                        }
                    }
                }
                if details.hasBackground {
                    Button("Subagents & Tasks", systemImage: "square.stack.3d.down.right") { perform(.background) }
                }
                if details.bellInMenu {
                    // The session's bell, with its state: on by default; off, it never notifies you.
                    Button(details.notificationsMuted ? "Turn On Notifications" : "Mute Notifications",
                           systemImage: details.notificationsMuted ? "bell.slash" : "bell") {
                        perform(.toggleNotifications)
                    }
                }
                // This session's tab in the integrated browser, where its agent browses.
                Button("Browser", systemImage: "safari") { perform(.browser) }
            }
            if details.loaded {
                // The session itself: its name and the ids other tools know it by.
                Section {
                    Button("Session Info…", systemImage: "info.circle") { perform(.info) }
                    Button("Rename…", systemImage: "pencil") { perform(.rename) }
                    if let path = details.folderPath {
                        FolderColorMenu(path: path, current: details.folderColor) { perform(.folderColor($0)) }
                    }
                    if details.nested {
                        Button { perform(.moveToTopLevel) } label: {
                            Label("Detach from Parent", image: "DetachFromParent")
                        }
                    }
                    SessionIDMenu(sessionId: details.sessionId, providerName: details.agentName,
                                  providerSessionId: details.vendorSessionId)
                }
                // Ending things, last.
                Section {
                    if details.active {
                        Button("Stop Agent", systemImage: "stop.circle") { perform(.stopAgent) }
                        Button("Stop Session", systemImage: "power", role: .destructive) { perform(.stopSession) }
                    } else {
                        ResumeSessionButton(sessionId: details.sessionId)
                    }
                    if details.archived {
                        Button("Unarchive", systemImage: "tray.and.arrow.up") { perform(.unarchive) }
                    } else {
                        Button("Archive", systemImage: "archivebox") { perform(.archive) }
                    }
                    if details.deletable {
                        Button("Delete…", systemImage: "trash", role: .destructive) { perform(.delete) }
                    }
                }
            }
        } label: {
            Label("Details", systemImage: "info.circle")
        }
    }
}

/// The conversation's scroll bookkeeping, read by its handlers rather than drawn.
@MainActor
final class ChatScrollState {
    var geometry: ChatScroll.Geometry?
    var visibleIds: [String] = []
    var followScheduled = false
}

/// The session's bell: on by default. Off, the session never notifies you; it still reports to
/// its parent session, which notifies as usual.
struct SessionBellButton: View {
    let sessionId: String
    @Environment(HappierStore.self) private var store

    var body: some View {
        let muted = store.sessions[sessionId]?.notificationsMuted == true
        Button {
            AppHaptics.selection()
            Task { await store.setNotificationsMuted(!muted, in: sessionId) }
        } label: {
            Label(muted ? "Turn On Notifications" : "Mute Notifications", systemImage: muted ? "bell.slash" : "bell")
        }
        .help(muted ? "This session doesn't notify you. Turn its notifications back on."
                    : "Stop notifications from this session. It still reports to its parent session.")
    }
}

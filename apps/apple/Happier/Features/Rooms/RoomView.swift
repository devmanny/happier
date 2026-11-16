import HappierKit
import SwiftUI

/// A room's chat: who said what, oldest first; the agents replying now; the members another agent
/// mentioned that wait for you ("Let … Answer", or dismiss it until an agent mentions it again); the
/// brake after six agent turns in a row; and the pause. Your message reaches the members you mention
/// with @ (`@todos` is everyone); with no one mentioned, @todos and the last agent who spoke are
/// suggested. Reply (the message's menu, a swipe to the left on iPhone and iPad, a button on hover on
/// the Mac) quotes a message and reaches only its author, plus whoever you mention. An agent's
/// `<options>` show as the session chat's buttons; picking one answers only that agent. Delivery is
/// the members' daemons' (`decideRoomDelivery`). While it is on screen, its members' threads are
/// read (`HappierStore.readRoomThreads`): their replies are read here, so the session list and the
/// agents' circles stop counting them, on every device.
///
/// An agent's own chat (`AgentRoom.isDirect`, opened by `AgentChatView`) reads like Messages: no
/// names or avatars, bubbles with their tail on the last of a run, the time centered between runs,
/// "New thread" above its first reply from a new thread (its daemon replaced a thread that was
/// archived or gone), "Read" under your last message once the agent has it, its typing bubble while
/// it works, and no @: everything you write reaches it. What you write while it works waits for that turn to end: those
/// messages sit dimmed below the typing bubble, with why they wait (`AgentRoom.queued`), and can be
/// edited or canceled until the agent gets them (`HappierStore.reviseQueuedRoomMessage`); once it
/// does, they take their place by seq. Its header and info are `AgentChatView`'s.
struct RoomView: View {
    let roomId: String
    @Environment(HappierStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    @State private var sending = false
    @State private var showMembers = false
    /// The message being answered (Reply), by seq.
    @State private var replyingTo: Int?
    /// The message a tapped quote scrolled to, lit for a moment.
    @State private var highlighted: Int?
    /// "Let It Answer" notices dismissed here whose write is under way: hidden at once.
    @State private var dismissing: Set<String> = []
    @FocusState private var composing: Bool
    /// The mic, as in the session's composer: a tap dictates into the field; held, push to talk.
    @State private var dictation = Dictation()
    @State private var talking = false
    @State private var talkCancelArmed = false
    @State private var textBeforeTalking = ""
    @State private var trashX: CGFloat?
    @State private var micX: CGFloat?
    @State private var choosingModel = false
    /// The waiting message being edited, by seq, and its text in the editor.
    @State private var editingQueued: Int?
    @State private var queuedEditText = ""
    /// An edit or cancel came too late: the agent already had the message.
    @State private var tooLate = false

    private var room: AgentRoom? { store.room(id: roomId) }
    private var messages: [AgentRoomMessage] { store.roomMessages[roomId] ?? [] }
    private var seats: [AgentRoomSeat] { store.roomSeats[roomId] ?? [] }
    /// In an agent's chat, the agent's own session: its model, effort and voice are that session's.
    private var directSession: String? { store.room(id: roomId)?.isDirect == true ? seats.first?.sessionId : nil }

    var body: some View {
        Group {
            if let room {
                chat(room)
            } else if store.rooms.isEmpty {
                HappierSpinner(size: HappierSpinner.hero)
            } else {
                ContentUnavailableView("Room Not Found", systemImage: "bubble.left.and.exclamationmark.bubble.right",
                                       description: Text("It may have been archived or deleted on another device."))
            }
        }
        .task(id: roomId) {
            replyingTo = nil
            if store.room(id: roomId) == nil { await store.refreshRooms() }
            await store.loadRoom(id: roomId)
        }
        .onChange(of: store.unreadRoomThreads(roomId: roomId), initial: true) { _, unread in
            if !unread.isEmpty { store.readRoomThreads(roomId: roomId) }
        }
        .alert("Edit Message", isPresented: Binding(get: { editingQueued != nil }, set: { if !$0 { editingQueued = nil } })) {
            TextField("Message", text: $queuedEditText, axis: .vertical)
                .accessibilityIdentifier("room-queued-edit-field")
            Button("Save") {
                let text = queuedEditText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let seq = editingQueued, !text.isEmpty, text != messages.first(where: { $0.seq == seq })?.text else { return }
                revise(seq, text: text)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It hasn't reached \(room?.title ?? "") yet.")
        }
        .sheet(isPresented: $showMembers) {
            RoomMembersSheet(roomId: roomId)
                #if os(macOS)
                .frame(minWidth: 420, minHeight: 420)
                #endif
        }
    }

    private func chat(_ room: AgentRoom) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: room.isDirect ? 3 : 10) {
                    if messages.isEmpty {
                        Group {
                            if room.isDirect {
                                Text("Write to \(room.title). It works in \(room.members.first?.directory ?? "")")
                            } else {
                                Text("Mention an agent with @ to start, or everyone with @todos: \(room.members.compactMap(\.name).map { "@\($0)" }.joined(separator: ", ")).")
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }
                    // In an agent's chat, what it doesn't have yet waits at the bottom (`queuedRows`).
                    let queue = room.queued(seats: seats, messages: messages)
                    let waiting = Set(queue?.messages.map(\.seq) ?? [])
                    let delivered = waiting.isEmpty ? messages : messages.filter { !waiting.contains($0.seq) }
                    let layout = room.isDirect ? DirectLayout(messages: delivered, seats: seats) : nil
                    ForEach(delivered) { message in
                        let separator = layout?.separators[message.seq]
                        let newThread = layout?.newThreads.contains(message.seq) == true
                        if separator != nil || newThread {
                            VStack(spacing: 2) {
                                if let separator { Text(verbatim: ChatDate.separatorLabel(separator)) }
                                if newThread { newThreadCaption(room) }
                            }
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                        }
                        RoomMessageRow(message: message, room: room, messages: messages, highlighted: highlighted == message.seq,
                                       direct: room.isDirect, tail: layout?.tails.contains(message.seq) ?? true,
                                       read: layout?.readSeq == message.seq) { option in
                            Task { await store.answerRoomOption(roomId: roomId, message: message, option: option) }
                        } reply: {
                            startReply(to: message)
                        } showQuoted: { seq in
                            show(seq, proxy: proxy)
                        }
                        .id(message.seq)
                    }
                    if room.isDirect {
                        if !replying(room).isEmpty {
                            TypingIndicator()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("replying")
                        }
                        queuedRows(room, queue, proxy: proxy)
                    } else {
                        ForEach(replying(room)) { member in
                            Label("\(member.name ?? member.agentId) is replying…", systemImage: "ellipsis.bubble")
                                .font(.footnote)
                                .foregroundStyle(Color.userBubble)
                                .padding(.leading, 4)
                                .id("replying-\(member.agentId)")
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.last?.seq) { _, last in
                guard let last else { return }
                withAnimation(reduceMotion ? nil : .smooth) { proxy.scrollTo(last, anchor: .bottom) }
            }
            .safeAreaInset(edge: .bottom) { bottom(room) }
        }
        .navigationTitle(Text(verbatim: room.title))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if !room.isDirect { groupToolbar(room) }
        }
    }

    @ToolbarContentBuilder
    private func groupToolbar(_ room: AgentRoom) -> some ToolbarContent {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    AppHaptics.light()
                    showMembers = true
                } label: {
                    Label("Members", systemImage: "person.2")
                }
                .accessibilityIdentifier("room-members")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    AppHaptics.light()
                    Task { await store.setRoomPaused(id: roomId, !room.isPaused) }
                } label: {
                    Label(room.isPaused ? "Resume" : "Pause", systemImage: room.isPaused ? "play.fill" : "pause.fill")
                }
                .help(Text(room.isPaused ? "Resume: deliver what's waiting" : "Pause: nothing more is delivered; running turns finish"))
                .accessibilityIdentifier("room-pause")
            }
    }

    /// "New thread", quiet like the time above a run: the agent's reply below it came from a new
    /// thread (`AgentRoom.newThreadSeqs`).
    private func newThreadCaption(_ room: AgentRoom) -> some View {
        let why = String(localized: "\(room.title) continues in a new thread, starting from a recap of this chat.")
        return Text("New thread")
            .help(Text(verbatim: why))
            .accessibilityHint(Text(verbatim: why))
            .accessibilityIdentifier("room-new-thread")
    }

    private func startReply(to message: AgentRoomMessage) {
        AppHaptics.light()
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { replyingTo = message.seq }
        composing = true
    }

    /// Scrolls to the message a quote answers and lights it for a moment.
    private func show(_ seq: Int, proxy: ScrollViewProxy) {
        AppHaptics.light()
        withAnimation(reduceMotion ? nil : .smooth) { proxy.scrollTo(seq, anchor: .center) }
        highlighted = seq
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard highlighted == seq else { return }
            withAnimation(.easeOut(duration: 0.5)) { highlighted = nil }
        }
    }

    // MARK: What waits for the agent

    /// Your messages the agent doesn't have yet, dimmed at the bottom of its chat with why they
    /// wait: edit or cancel one from its menu (or a tap) until the agent gets it.
    @ViewBuilder
    private func queuedRows(_ room: AgentRoom, _ queue: AgentRoom.Queue?, proxy: ScrollViewProxy) -> some View {
        let name = room.title
        VStack(alignment: .trailing, spacing: 3) {
            if let queue {
                let status = queue.reason == .afterCurrentTurn
                    ? String(localized: "Waiting · \(name) gets this after the current turn")
                    : String(localized: "Waiting · Not delivered yet")
                ForEach(queue.messages) { message in
                    let waiting = RoomMessageRow.Waiting(status: status, revisable: queue.revisable,
                                                         edit: { beginEdit(message) }, cancel: { revise(message.seq, text: nil) })
                    RoomMessageRow(message: message, room: room, messages: messages, highlighted: highlighted == message.seq,
                                   direct: true, tail: message.seq == queue.messages.last?.seq, waiting: waiting,
                                   pick: { _ in }, reply: {}, showQuoted: { show($0, proxy: proxy) })
                        .id(message.seq)
                        .transition(.opacity)
                }
                Text(verbatim: status)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)
                    .padding(.bottom, 4)
                    .accessibilityIdentifier("room-queue-status")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: queue?.messages.map(\.seq))
    }

    private func beginEdit(_ message: AgentRoomMessage) {
        queuedEditText = message.text
        editingQueued = message.seq
    }

    /// Edits (`text`) or cancels the waiting message; when the agent got it first, says so.
    private func revise(_ seq: Int, text: String?) {
        Task {
            switch await store.reviseQueuedRoomMessage(roomId: roomId, seq: seq, text: text) {
            case .done:
                AppHaptics.success()
            case .alreadyDelivered:
                AppHaptics.warning()
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { tooLate = true }
                try? await Task.sleep(for: .seconds(4))
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { tooLate = false }
            case .failed:
                break
            }
        }
    }

    /// Members whose thread is working a turn for this room.
    private func replying(_ room: AgentRoom) -> [AgentRoom.Member] {
        let busy = Set(seats.filter { $0.inFlight != nil }.map(\.agentId))
        return room.members.filter { busy.contains($0.agentId) }
    }

    // MARK: Bottom: notices and the composer

    @ViewBuilder
    private func bottom(_ room: AgentRoom) -> some View {
        VStack(spacing: 8) {
            if room.isPaused {
                notice("Paused: nothing is delivered until you resume.", systemImage: "pause.circle.fill", tint: .orange) {
                    Button("Resume") { Task { await store.setRoomPaused(id: roomId, false) } }
                }
            } else if AgentRoom.brakeHolds(messages) {
                notice("\(AgentRoom.maxAgentTurns) agent turns in a row: write to let them go on.", systemImage: "hand.raised.fill", tint: .orange) {
                    EmptyView()
                }
            }
            if tooLate {
                notice("\(room.title) already has it, so it can't be changed now.", systemImage: "checkmark.circle.fill", tint: Color.userBubble) {
                    Button("OK") { withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { tooLate = false } }
                        .accessibilityIdentifier("room-too-late-ok")
                }
                .transition(.opacity)
                .accessibilityIdentifier("room-too-late")
            }
            let waits = room.waitingForUser(seats: seats, messages: messages).filter { !dismissing.contains(Self.key($0)) }
            if !waits.isEmpty {
                waitingRow(room, waits)
            }
            composer(room)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private static func key(_ wait: AgentRoom.Wait) -> String { "\(wait.agentId)#\(wait.mentionSeq)" }

    /// The members another agent mentioned that wait for you, in one row: let each one answer, or
    /// dismiss it (it doesn't answer that mention; it comes back when an agent mentions it again).
    private func waitingRow(_ room: AgentRoom, _ waits: [AgentRoom.Wait]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "person.wave.2")
                .foregroundStyle(Color.userBubble)
                .accessibilityHidden(true)
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 4) {
                    HStack(spacing: 10) {
                        ForEach(waits, id: \.agentId) { wait in waitChip(room, wait) }
                    }
                    .padding(.vertical, 2)
                    .padding(.trailing, 4)
                }
            }
            .scrollClipDisabled()
        }
        .padding(.leading, 6)
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("room-waiting")
    }

    private func waitChip(_ room: AgentRoom, _ wait: AgentRoom.Wait) -> some View {
        let name = room.memberName(wait.agentId)
        let why = wait.mentionedBy.map { String(localized: "\(room.memberName($0)) mentioned \(name). It answers when you let it.") }
            ?? String(localized: "Another agent mentioned \(name). It answers when you let it.")
        return HStack(spacing: 4) {
            Button("Let \(name) Answer") {
                AppHaptics.light()
                Task { await store.letRoomMemberAnswer(roomId: roomId, agentId: wait.agentId) }
            }
            .accessibilityHint(Text(verbatim: why))
            .accessibilityIdentifier("room-let-answer-\(wait.agentId)")
            Button {
                dismiss(wait)
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.semibold))
            }
            .buttonBorderShape(.circle)
            .accessibilityLabel(Text("Dismiss \(name)"))
            .accessibilityHint(Text("It doesn't answer this mention. It asks again when an agent mentions it."))
            .accessibilityIdentifier("room-dismiss-wait-\(wait.agentId)")
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .help(Text(verbatim: why))
    }

    private func dismiss(_ wait: AgentRoom.Wait) {
        AppHaptics.light()
        let key = Self.key(wait)
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { _ = dismissing.insert(key) }
        Task {
            await store.dismissRoomWait(roomId: roomId, agentId: wait.agentId, mentionSeq: wait.mentionSeq)
            dismissing.remove(key)
        }
    }

    private func notice(_ text: LocalizedStringKey, systemImage: String, tint: Color,
                        @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            action()
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// The message being answered, while it is still in the room's window.
    private var quoted: AgentRoomMessage? {
        replyingTo.flatMap { seq in messages.first { $0.seq == seq } }
    }

    @ViewBuilder
    private func composer(_ room: AgentRoom) -> some View {
        let quoted = quoted
        // Who it reaches: a reply's author and whoever the draft mentions (`AgentRoom.replying`).
        let mentioned = quoted.map { room.replyRecipients(to: $0, text: draft) } ?? AgentRoom.mentions(in: draft, members: room.members)
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 6) {
            if MessageSpeaker.shared.speakingText != nil {
                // What's being read aloud, with its controls, as above the session's composer.
                SpeechControls()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let quoted {
                replyBar(room, quoted: quoted, recipients: mentioned)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if room.isDirect {
                EmptyView()
            } else if let partial = partialMention(), case let chips = AgentRoom.mentionSuggestions(for: partial, members: room.members), !chips.isEmpty {
                // Completing the @ being typed: everyone first.
                chipRow(chips, room: room) { complete(with: $0.label(members: room.members)) }
            } else if !typed.isEmpty, mentioned.isEmpty {
                // Without @ it reaches no one: everyone, and the last agent who spoke, are suggested.
                let last = AgentRoom.lastAgentSpeaker(messages).map { AgentRoom.MentionSuggestion.member($0) }
                HStack(spacing: 6) {
                    Text("No one is mentioned.").font(.caption).foregroundStyle(.secondary)
                    chipRow([.everyone] + (last.map { [$0] } ?? []), room: room) { chip in
                        draft = chip.label(members: room.members) + " " + draft
                    }
                }
                .accessibilityIdentifier("room-suggest-mention")
            }
            if room.isDirect, let sessionId = directSession, let controls = store.controls(for: sessionId) {
                modelPill(controls, sessionId: sessionId)
            }
            if talking {
                TalkPanel(levels: dictation.levels, cancelArmed: talkCancelArmed)
                    .frame(height: 36)
                    .padding(.horizontal, 8)
                    .glassEffect(.regular, in: Capsule())
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX + 8 + TalkPanel.trashCenter } action: { trashX = $0 }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(room.isDirect ? LocalizedStringKey("Message \(room.title)")
                                        : LocalizedStringKey("Message the room · @ to mention, @todos for everyone"),
                          text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composing)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .onSubmit(send)
                    .accessibilityIdentifier("room-composer")
                if typed.isEmpty || dictation.isRecording || talking {
                    // Tap: dictate into the field. Hold: push to talk, sent when released.
                    PushToTalkButton(recording: dictation.isRecording, talking: talking, cancelArmed: $talkCancelArmed,
                                     trashOffset: trashX.flatMap { trash in micX.map { trash - $0 } }) {
                        AppHaptics.light()
                        if dictation.isRecording { Task { await dictation.finish() } } else { dictation.toggle(prefix: draft) { draft = $0 } }
                    } onHoldStart: {
                        startTalking()
                    } onHoldEnd: { cancelled in
                        stopTalking(cancelled: cancelled)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midX } action: { micX = $0 }
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.semibold))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .disabled(sending)
                    .accessibilityLabel(Text("Send"))
                    .accessibilityIdentifier("room-send")
                }
            }
        }
        .animation(.smooth(duration: 0.2), value: talking)
        .onDisappear { if dictation.isRecording { dictation.stop() } }
    }

    /// The agent's model and effort, as the session composer's pill: changed here, they apply from
    /// your next message. It never offers another agent or provider: the chat sends through
    /// `sendRoomMessage`, which never applies an armed switch. It always runs in YOLO.
    private func modelPill(_ controls: SessionControls, sessionId: String) -> some View {
        Button {
            AppHaptics.light()
            choosingModel = true
        } label: {
            HStack(spacing: 5) {
                Text(controls.displayModelName).lineLimit(1)
                if let effort = controls.displayEffort,
                   let bars = EffortBars(level: effort, levels: controls.effortModel?.effortLevels ?? [], ultracode: controls.ultracode == true) {
                    EffortBarsMark(bars: bars)
                        .accessibilityLabel(Text(controls.ultracode == true ? "Effort Ultracode" : "Effort \(EffortSlider.name(effort))"))
                }
                Text(verbatim: "· YOLO").foregroundStyle(.secondary)
            }
            .font(.footnote.weight(.medium))
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .accessibilityLabel(Text("Model"))
        .accessibilityIdentifier("room-model")
        #if os(macOS)
        .popover(isPresented: $choosingModel, arrowEdge: .top) {
            SessionModelPicker(sessionId: sessionId, allowsAgentSwitch: false).frame(width: 340, height: 520)
        }
        #else
        .sheet(isPresented: $choosingModel) {
            ModelPickerSheet { SessionModelPicker(sessionId: sessionId, allowsAgentSwitch: false) }
                .presentationDetents([.medium, .large])
        }
        #endif
    }

    /// Push to talk, as in the session's composer; in an agent's chat its answers are read aloud
    /// from then on.
    private func startTalking() {
        guard !talking else { return }
        textBeforeTalking = draft
        talkCancelArmed = false
        talking = true
        dictation.claimAudio()
        if let sessionId = directSession, MessageSpeaker.shared.autoReadSessionId != sessionId {
            MessageSpeaker.shared.toggleAutoRead(sessionId, store: store)
        }
        Task {
            guard talking else { return }
            await dictation.begin(prefix: draft) { draft = $0 }
        }
    }

    /// Released: the last words come in, then it's sent; slid onto the trash, nothing is sent.
    private func stopTalking(cancelled: Bool) {
        if cancelled {
            dictation.stop()
            draft = textBeforeTalking
            talking = false
            talkCancelArmed = false
            AppHaptics.listening(false, cancelled: true)
            return
        }
        AppHaptics.listening(false)
        Task {
            await dictation.finish()
            guard talking else { return }
            talking = false
            send()
        }
    }

    /// The message being answered, above the field: who wrote it, its first line, who will be
    /// notified (its author and whoever the draft mentions), and ✕ to stop replying.
    private func replyBar(_ room: AgentRoom, quoted: AgentRoomMessage, recipients: [String]) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Capsule()
                .fill(Color.userBubble)
                .frame(width: 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Replying to \(room.displayName(of: quoted.author))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.userBubble)
                Text(verbatim: quoted.quotePreview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !recipients.isEmpty {
                    Label(Self.notified(recipients.map(room.memberName)), systemImage: "bell")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("room-reply-recipients")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                AppHaptics.light()
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { replyingTo = nil }
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.semibold))
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .accessibilityLabel(Text("Cancel Reply"))
            .accessibilityIdentifier("room-reply-cancel")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("room-reply-bar")
    }

    /// "Only Julián will be notified"; "Julián and Mateo will be notified".
    private static func notified(_ names: [String]) -> String {
        names.count == 1
            ? String(localized: "Only \(names[0]) will be notified")
            : String(localized: "\(names.formatted(.list(type: .and))) will be notified")
    }

    private func chipRow(_ chips: [AgentRoom.MentionSuggestion], room: AgentRoom,
                         pick: @escaping (AgentRoom.MentionSuggestion) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chips, id: \.self) { chip in
                    Button(chip.label(members: room.members)) { pick(chip) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .accessibilityIdentifier(chip == .everyone ? "room-chip-everyone" : "room-chip-\(chip.label(members: room.members))")
                }
            }
        }
    }

    /// The `@word` being typed at the end of the draft, without the `@`.
    private func partialMention() -> String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at > draft.startIndex, let before = draft[..<at].last, before.isLetter || before.isNumber { return nil }
        let word = draft[draft.index(after: at)...]
        return word.contains(where: \.isWhitespace) ? nil : String(word)
    }

    private func complete(with label: String) {
        guard let at = draft.lastIndex(of: "@") else { return }
        draft = String(draft[..<at]) + label + " "
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        if dictation.isRecording { dictation.stop() }
        sending = true
        let quoted = quoted
        Task {
            let sent = await store.sendRoomMessage(roomId: roomId, text: text, replyingTo: quoted)
            sending = false
            if sent {
                AppHaptics.light()
                if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
                if let quoted, replyingTo == quoted.seq { replyingTo = nil }
            }
        }
    }
}

/// How an agent's chat lays its messages out, as Messages does: the time centered before the first
/// message and after each pause (`ChatDate.separatorGap`), "New thread" centered above the agent's
/// first reply from a new thread (`AgentRoom.newThreadSeqs`), the tail on the last bubble of each run
/// of one author, and "Read" under your last message once the agent has it (its seat read through it,
/// or its turn is reading it).
private struct DirectLayout {
    /// The time shown above each message that starts after a pause, by seq.
    var separators: [Int: Date] = [:]
    /// The agent's replies with "New thread" above them.
    var newThreads: Set<Int> = []
    /// The messages that end a run.
    var tails: Set<Int> = []
    /// Your last message, once the agent has read it.
    var readSeq: Int?

    init(messages: [AgentRoomMessage], seats: [AgentRoomSeat]) {
        func date(_ message: AgentRoomMessage) -> Date { Date(timeIntervalSince1970: message.at / 1000) }
        for (index, message) in messages.enumerated() {
            let previous = index > 0 ? messages[index - 1] : nil
            if previous.map({ date(message).timeIntervalSince(date($0)) > ChatDate.separatorGap }) ?? true {
                separators[message.seq] = date(message)
            }
        }
        newThreads = AgentRoom.newThreadSeqs(in: messages)
        for (index, message) in messages.enumerated() {
            let next = index + 1 < messages.count ? messages[index + 1] : nil
            if next.map({ $0.author != message.author || separators[$0.seq] != nil || newThreads.contains($0.seq) }) ?? true {
                tails.insert(message.seq)
            }
        }
        let read = seats.map(\.deliveredThroughSeq).max() ?? 0
        if let last = messages.last(where: { $0.author == .user }), last.seq <= read { readSeq = last.seq }
    }
}

/// One message: yours on the right in your color; an agent's on the left under its emoji and name,
/// Markdown like the session chat, with its `<options>` as the chat's buttons and the sessions it
/// names as cards between its bubbles (`SessionReferenceCard`). Mentions are in bold;
/// the message it answers is quoted above it (tap it to go there). Reply is in its menu, a swipe to
/// the left on iPhone and iPad, and a button on hover on the Mac. One of yours the agent doesn't
/// have yet (`waiting`) is dimmed, and a tap or its menu edits, cancels or copies it instead.
private struct RoomMessageRow: View {
    /// Your message waiting for the agent (`AgentRoom.queued`), and what can be done with it.
    struct Waiting {
        /// Why it waits, for its actions' title.
        let status: String
        /// False before the agent's first delivery: it can only be copied.
        let revisable: Bool
        let edit: () -> Void
        let cancel: () -> Void
    }

    let message: AgentRoomMessage
    let room: AgentRoom
    let messages: [AgentRoomMessage]
    /// Lit for a moment: a quote of it was tapped.
    let highlighted: Bool
    /// In an agent's chat: no name or avatar, the tail only on the last of a run, and "Read".
    var direct = false
    var tail = true
    var read = false
    var waiting: Waiting?
    let pick: (String) -> Void
    let reply: () -> Void
    let showQuoted: (Int) -> Void
    @Environment(HappierStore.self) private var store
    /// Its TL;DR is shown instead of it (`TLDRButton`).
    @State private var showsSummary = false
    private var summaryId: String { "room-\(message.roomId)-\(message.seq)" }
    /// The TL;DR the bubble shows, if it shows one.
    private var shownSummary: String? { showsSummary ? MessageSummaries.shared.summaries[summaryId] : nil }
    /// A waiting message's actions, after a tap.
    @State private var showWaitingActions = false
    #if os(iOS)
    /// How far the message is dragged to the left to reply (≤ 0).
    @State private var swipe: CGFloat = 0
    #else
    @State private var hovering = false
    #endif

    private var isUser: Bool { message.author == .user }

    private var emoji: String? {
        if case .agent(let id, _, let emoji, _) = message.author { return emoji ?? room.members.first { $0.agentId == id }?.emoji }
        return nil
    }

    private var providerId: String? {
        message.author.agentId.flatMap { store.agentProfile(id: $0)?.providerId }
    }

    /// The text with its mentions in bold (Markdown), outside code.
    private func boldMentions(_ prose: String) -> String {
        var text = prose
        for range in AgentRoom.mentionRanges(in: prose, members: room.members).reversed() {
            text.replaceSubrange(range, with: "**\(prose[range])**")
        }
        return text
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: direct ? 64 : 48) }
            #if os(macOS)
            if isUser, waiting == nil { hoverReply }
            #endif
            if !isUser, !direct {
                AgentAvatar(agentId: providerId, size: 28, emoji: emoji, photo: message.author.agentId.flatMap { store.agentPhotos[$0] })
            }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                if !isUser, !direct {
                    Text(room.displayName(of: message.author)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                if let replyTo = message.replyTo, let answered = messages.first(where: { $0.seq == replyTo }) {
                    quote(answered)
                }
                Group {
                    if isUser { userBubble } else { agentBubble }
                }
                if !direct {
                    Text(Date(timeIntervalSince1970: message.at / 1000), format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if read {
                    Text("Read")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                        .padding(.bottom, 4)
                        .accessibilityIdentifier("room-read")
                }
            }
            #if os(macOS)
            if !isUser { hoverReply }
            #endif
            if !isUser { Spacer(minLength: direct ? 64 : 48) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.userBubble.opacity(highlighted ? 0.14 : 0))
                .padding(-6)
                .allowsHitTesting(false)
        }
        #if os(iOS)
        .offset(x: swipe)
        .background(alignment: .trailing) {
            Image(systemName: "arrowshape.turn.up.left.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.userBubble)
                .opacity(min(1, -swipe / RoomReplySwipe.threshold))
                .scaleEffect(swipe <= -RoomReplySwipe.threshold ? 1 : 0.7)
                .animation(.smooth(duration: 0.15), value: swipe <= -RoomReplySwipe.threshold)
                .accessibilityHidden(true)
        }
        .gesture(RoomReplySwipe { translation in
            guard waiting == nil else { return }
            // Past the threshold it gives, with a tick, like Messages.
            let pulled = translation < -RoomReplySwipe.threshold ? -RoomReplySwipe.threshold + (translation + RoomReplySwipe.threshold) / 3 : translation
            if (pulled <= -RoomReplySwipe.threshold) != (swipe <= -RoomReplySwipe.threshold) { AppHaptics.selection() }
            swipe = pulled
        } onEnd: { translation in
            if waiting == nil, translation <= -RoomReplySwipe.threshold { reply() }
            withAnimation(.spring(duration: 0.3)) { swipe = 0 }
        })
        #else
        .onHover { hovering = $0 }
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            if let waiting {
                if waiting.revisable {
                    Button("Edit", action: waiting.edit)
                    Button("Cancel Message", action: waiting.cancel)
                }
            } else {
                Button("Reply", action: reply)
            }
        }
        .accessibilityIdentifier(waiting == nil ? "room-message-\(message.seq)" : "room-queued-\(message.seq)")
    }

    #if os(macOS)
    /// Reply, beside the message while the pointer is over it.
    private var hoverReply: some View {
        Button(action: reply) {
            Image(systemName: "arrowshape.turn.up.left")
                .font(.callout)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(Text("Reply"))
        .opacity(hovering ? 1 : 0)
        .allowsHitTesting(hovering)
        .padding(.bottom, 20)
        .accessibilityHidden(true)
    }
    #endif

    /// Reply, Copy and Speak under its date and time, as in the session chat.
    @ViewBuilder
    private var actions: some View {
        Section(Date(timeIntervalSince1970: message.at / 1000).formatted(date: .abbreviated, time: .shortened)) {
            Button("Reply", systemImage: "arrowshape.turn.up.left", action: reply)
            Button("Copy", systemImage: "doc.on.doc") { MessageClipboard.copy(message.text); AppHaptics.success() }
            // What the bubble shows is what's read: its TL;DR while that's shown.
            let spoken = shownSummary ?? message.text
            let speaking = MessageSpeaker.shared.isSpeaking(spoken)
            Button(speaking ? "Stop Speaking" : "Speak", systemImage: speaking ? "stop.circle" : "speaker.wave.2") {
                AppHaptics.light()
                MessageSpeaker.shared.toggle(spoken,
                                             sessionId: room.isDirect ? store.roomSeats[room.id]?.first?.sessionId : nil)
            }
        }
    }

    /// A waiting message's actions: Edit and Cancel Message while the agent hasn't got it, and Copy.
    @ViewBuilder
    private func waitingActions(_ waiting: Waiting) -> some View {
        if waiting.revisable {
            Button("Edit", systemImage: "pencil") { AppHaptics.light(); waiting.edit() }
            Button("Cancel Message", systemImage: "xmark.circle", role: .destructive) { AppHaptics.warning(); waiting.cancel() }
        }
        Button("Copy", systemImage: "doc.on.doc") { MessageClipboard.copy(message.text); AppHaptics.success() }
    }

    /// "↩︎ Julián: …": the message this one answers, in a line; tapping it goes there.
    private func quote(_ answered: AgentRoomMessage) -> some View {
        Button {
            showQuoted(answered.seq)
        } label: {
            Text("↩︎ \(room.displayName(of: answered.author)): \(answered.quotePreview)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 280, alignment: isUser ? .trailing : .leading)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Shows the message it answers"))
    }

    private var userBubble: some View {
        var text = AttributedString(message.text)
        for range in AgentRoom.mentionRanges(in: message.text, members: room.members) {
            if let lower = AttributedString.Index(range.lowerBound, within: text), let upper = AttributedString.Index(range.upperBound, within: text) {
                text[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            }
        }
        // No `.textSelection`: on the Mac a selectable text answers a right-click with the text
        // system's menu, hiding Reply; Copy is in the bubble's menu, as in the session chat.
        let shape = direct ? AnyShape(BubbleShape(fromUser: true, tail: tail)) : AnyShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        return Text(text)
            .modifier(BubbleInsets(direct: direct, fromUser: true))
            .foregroundStyle(Color.white)
            // Waiting, it is dimmed like the session chat's queued messages.
            .background(Color.userBubble.opacity(waiting == nil ? 1 : 0.55), in: shape)
            #if os(iOS)
            .contentShape(.contextMenuPreview, shape)
            #endif
            .contextMenu {
                if let waiting { waitingActions(waiting) } else { actions }
            }
            .modifier(WaitingTap(waiting: waiting, text: message.text, showActions: $showWaitingActions) { waitingActions($0) })
    }

    /// The reply's blocks in order: each run of text is one bubble, and the sessions it names
    /// (`MarkdownSegments.Segment.sessions`) are cards between them. Its `<options>` are left out
    /// (they go below everything).
    private enum Run {
        case text([MarkdownSegments.Segment])
        case sessions([String])
    }

    private func runs(_ segments: [MarkdownSegments.Segment]) -> [Run] {
        var runs: [Run] = []
        for segment in segments {
            switch (segment, runs.last) {
            case (.options, _):
                continue
            case (.sessions(let ids), .sessions(let before)?):
                runs[runs.count - 1] = .sessions(before + ids)
            case (.sessions(let ids), _):
                runs.append(.sessions(ids))
            case (_, .text(let before)?):
                runs[runs.count - 1] = .text(before + [bolded(segment)])
            case (_, _):
                runs.append(.text([bolded(segment)]))
            }
        }
        return runs
    }

    private func bolded(_ segment: MarkdownSegments.Segment) -> MarkdownSegments.Segment {
        if case .prose(let text) = segment { return .prose(boldMentions(text)) }
        return segment
    }

    /// Its bubbles and session cards, then its options. The whole row stays one message (one reply,
    /// one swipe); its menu is on each bubble and its TL;DR on the first one, which shows the TL;DR
    /// in place of the whole text while the cards stay. The tail goes on the last bubble only when
    /// nothing follows it.
    @ViewBuilder
    private var agentBubble: some View {
        let segments = MarkdownSegments.cached(message.text)
        let runs = runs(segments)
        let options = segments.flatMap { segment -> [String] in if case .options(let items) = segment { items } else { [] } }
        let summary = shownSummary
        let firstText = runs.firstIndex { !Self.isSessions($0) }
        // Everything, or while the TL;DR is shown, the first bubble (showing it) and the cards.
        let shown = runs.indices.filter { summary == nil || $0 == firstText || Self.isSessions(runs[$0]) }
        ForEach(shown, id: \.self) { index in
            switch runs[index] {
            case .text(let content):
                let bubbleTail = tail && options.isEmpty && index == shown.last
                if index == firstText {
                    textBubble(summary.map { MarkdownSegments.cached($0) } ?? content, tail: bubbleTail)
                        .tldr(id: summaryId, text: message.text, showsSummary: $showsSummary)
                } else {
                    textBubble(content, tail: bubbleTail)
                }
            case .sessions(let ids):
                // Lined up with the bubbles' body, past the room their tails take.
                SessionReferenceStack(ids: ids)
                    .padding(.leading, direct ? BubbleShape.tailWidth : 0)
            }
        }
        if !options.isEmpty {
            ReplyOptions(options: options, chosen: AgentRoom.chosenOption(on: message, options: options, messages: messages), onSelect: pick)
                .accessibilityIdentifier("room-options-\(message.seq)")
        }
    }

    private static func isSessions(_ run: Run) -> Bool {
        if case .sessions = run { true } else { false }
    }

    private func textBubble(_ content: [MarkdownSegments.Segment], tail: Bool) -> some View {
        let shape = direct ? AnyShape(BubbleShape(fromUser: false, tail: tail))
                           : AnyShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        return MarkdownText(segments: content)
            .modifier(BubbleInsets(direct: direct, fromUser: false))
            .background(Color.agentBubble, in: shape)
            #if os(iOS)
            .contentShape(.contextMenuPreview, shape)
            #endif
            .contextMenu { actions }
    }
}

/// A tap on a waiting message shows its actions (Edit, Cancel Message, Copy); other messages keep
/// theirs in the menu only.
private struct WaitingTap<Actions: View>: ViewModifier {
    let waiting: RoomMessageRow.Waiting?
    let text: String
    @Binding var showActions: Bool
    @ViewBuilder let actions: (RoomMessageRow.Waiting) -> Actions

    func body(content: Content) -> some View {
        if let waiting {
            content
                .onTapGesture { AppHaptics.light(); showActions = true }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(Text("Waiting for the agent. Shows actions for this message"))
                .confirmationDialog(text, isPresented: $showActions, titleVisibility: .visible) {
                    actions(waiting)
                    Button("Close", role: .cancel) {}
                } message: {
                    Text(verbatim: waiting.status)
                }
        } else {
            content
        }
    }
}

/// A bubble's insets: Messages' (room for the tail) in an agent's chat, the room's plain ones elsewhere.
private struct BubbleInsets: ViewModifier {
    let direct: Bool
    let fromUser: Bool

    func body(content: Content) -> some View {
        if direct {
            content.bubblePadding(fromUser: fromUser)
        } else {
            content.padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

/// The room's info: who is in it, where each one works, and whether another agent's mention wakes
/// it ("Answers other agents"; for Claude only past the Consumer Terms 3.7 warning).
private struct RoomMembersSheet: View {
    let roomId: String
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var warning: String?
    /// "Your name here" while it is edited; saved on Return or Done.
    @State private var userName = ""

    private func saveUserName() {
        guard let room = store.room(id: roomId),
              userName.trimmingCharacters(in: .whitespaces) != (room.userName ?? "") else { return }
        Task { await store.setRoomUserName(roomId: roomId, userName) }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let room = store.room(id: roomId) {
                    ForEach(room.members) { member in
                        Section {
                            LabeledContent("Machine", value: store.machines.first { $0.id == member.machineId }?.name ?? member.machineId)
                            LabeledContent("Folder", value: member.directory)
                            Toggle("Answers other agents", isOn: Binding(get: { member.wakeByAgents == true }, set: { on in
                                let providerId = store.agentProfile(id: member.agentId)?.providerId
                                if on, TaskRecurrence.needsAutomatedAccessWarning(providerId: providerId) {
                                    warning = member.agentId
                                } else {
                                    Task { await store.setRoomMemberAnswersAgents(roomId: roomId, agentId: member.agentId, on) }
                                }
                            }))
                            .accessibilityIdentifier("room-member-wake-\(member.agentId)")
                        } header: {
                            Text([member.emoji, member.name ?? member.agentId].compactMap { $0 }.joined(separator: " "))
                        }
                    }
                    Section {
                        TextField("Your name here", text: $userName, prompt: Text("User"))
                            .textContentType(.name)
                            .onSubmit(saveUserName)
                            .accessibilityIdentifier("room-user-name")
                    } header: {
                        Text("How the agents call you")
                    } footer: {
                        Text("Another agent's mention only wakes the agents that answer other agents; the others wait for you to let them answer.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Members")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveUserName()
                        dismiss()
                    }
                }
            }
            .onAppear { userName = store.room(id: roomId)?.userName ?? "" }
            .alert("Automated Access with Claude", isPresented: Binding(get: { warning != nil }, set: { if !$0 { warning = nil } })) {
                Button("Allow") {
                    if let id = warning { Task { await store.setRoomMemberAnswersAgents(roomId: roomId, agentId: id, true) } }
                    warning = nil
                }
                Button("Cancel", role: .cancel) { warning = nil }
            } message: {
                Text("""
                When another agent mentions it, it answers without you, which is automated access. Anthropic's Consumer Terms \
                (section 3.7) ask for an API key for that, not a Claude subscription. Otherwise it waits for you to let it answer.
                """)
            }
        }
    }
}

private extension AgentRoom {
    /// A member's name as the room shows it.
    func memberName(_ agentId: String) -> String {
        members.first { $0.agentId == agentId }?.name ?? agentId
    }

    /// Who wrote a message: your name in the room (or "You"), or the agent's as it wrote.
    func displayName(of author: AgentRoomMessage.Author) -> String {
        switch author {
        case .user: userName ?? String(localized: "You")
        case .agent(let id, let name, _, _): name ?? memberName(id)
        }
    }
}

private extension AgentRoomMessage {
    /// Its prose in one line (no code, options or session cards), for a quote.
    var quotePreview: String {
        MarkdownSegments.cached(text).compactMap { segment -> String? in
            if case .prose(let text) = segment { return text }
            return nil
        }.joined(separator: " ").replacingOccurrences(of: "\n", with: " ")
    }
}

#if os(iOS)
/// Dragging a message to the left replies to it. It only claims a drag that starts out horizontal
/// and leftward: the room still scrolls vertically, and a rightward drag stays the conversation's
/// (on iPhone it opens the sessions, `OpenSwipe`).
private struct RoomReplySwipe: UIGestureRecognizerRepresentable {
    /// How far to drag for the reply.
    static let threshold: CGFloat = 56
    var onChange: (CGFloat) -> Void
    var onEnd: (CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        // In window coordinates: the message moves with the finger, so its own space would not.
        let translation = min(recognizer.translation(in: recognizer.view?.window).x, 0)
        switch recognizer.state {
        case .began, .changed: onChange(translation)
        case .ended: onEnd(translation)
        case .cancelled, .failed: onEnd(0)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else { return false }
            let velocity = pan.velocity(in: view)
            return velocity.x < 0 && abs(velocity.x) > abs(velocity.y) * 1.2
        }
    }
}
#endif

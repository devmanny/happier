import HappierKit
import SwiftUI

/// A room's chat: who said what, oldest first; the agents replying now; the members another agent
/// mentioned that wait for you ("Let … Answer"); the brake after six agent turns in a row; and the
/// pause. Your message reaches the members you mention with @ (`@todos` is everyone); with no one
/// mentioned, @todos and the last agent who spoke are suggested. An agent's `<options>` show as the
/// session chat's buttons; picking one answers only that agent. Delivery is the members' daemons'
/// (`decideRoomDelivery`).
struct RoomView: View {
    let roomId: String
    @Environment(HappierStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    @State private var sending = false
    @State private var showMembers = false
    @FocusState private var composing: Bool

    private var room: AgentRoom? { store.room(id: roomId) }
    private var messages: [AgentRoomMessage] { store.roomMessages[roomId] ?? [] }
    private var seats: [AgentRoomSeat] { store.roomSeats[roomId] ?? [] }

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
            if store.room(id: roomId) == nil { await store.refreshRooms() }
            await store.loadRoom(id: roomId)
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
                LazyVStack(alignment: .leading, spacing: 10) {
                    if messages.isEmpty {
                        Text("Mention an agent with @ to start, or everyone with @todos: \(room.members.compactMap(\.name).map { "@\($0)" }.joined(separator: ", ")).")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(messages) { message in
                        RoomMessageRow(message: message, room: room, messages: messages) { option in
                            Task { await store.answerRoomOption(roomId: roomId, message: message, option: option) }
                        }
                        .id(message.seq)
                    }
                    ForEach(replying(room)) { member in
                        Label("\(member.name ?? member.agentId) is replying…", systemImage: "ellipsis.bubble")
                            .font(.footnote)
                            .foregroundStyle(Color.userBubble)
                            .padding(.leading, 4)
                            .id("replying-\(member.agentId)")
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
            ForEach(room.waitingForUser(seats: seats, messages: messages), id: \.self) { agentId in
                let name = room.members.first { $0.agentId == agentId }?.name ?? agentId
                notice("Another agent mentioned \(name). It answers when you let it.", systemImage: "person.wave.2", tint: Color.userBubble) {
                    Button("Let \(name) Answer") {
                        AppHaptics.light()
                        Task { await store.letRoomMemberAnswer(roomId: roomId, agentId: agentId) }
                    }
                    .accessibilityIdentifier("room-let-answer-\(agentId)")
                }
            }
            composer(room)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
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

    @ViewBuilder
    private func composer(_ room: AgentRoom) -> some View {
        let mentioned = AgentRoom.mentions(in: draft, members: room.members)
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 6) {
            if let partial = partialMention(), case let chips = AgentRoom.mentionSuggestions(for: partial, members: room.members), !chips.isEmpty {
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
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message the room · @ to mention, @todos for everyone", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composing)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .onSubmit(send)
                    .accessibilityIdentifier("room-composer")
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(typed.isEmpty || sending)
                .accessibilityLabel(Text("Send"))
                .accessibilityIdentifier("room-send")
            }
        }
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
        sending = true
        Task {
            let sent = await store.sendRoomMessage(roomId: roomId, text: text)
            sending = false
            if sent {
                AppHaptics.light()
                if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
            }
        }
    }
}

/// One message: yours on the right in your color (with the message it answers quoted above); an
/// agent's on the left under its emoji and name, Markdown like the session chat, with its
/// `<options>` as the chat's buttons. Mentions are in bold.
private struct RoomMessageRow: View {
    let message: AgentRoomMessage
    let room: AgentRoom
    let messages: [AgentRoomMessage]
    let pick: (String) -> Void
    @Environment(HappierStore.self) private var store

    private var isUser: Bool { message.author == .user }

    private func name(of author: AgentRoomMessage.Author) -> String {
        switch author {
        case .user: room.userName ?? String(localized: "You")
        case .agent(let id, let name, _, _): name ?? room.members.first { $0.agentId == id }?.name ?? id
        }
    }

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
            if isUser { Spacer(minLength: 48) }
            if !isUser {
                AgentAvatar(agentId: providerId, size: 28, emoji: emoji)
            }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                if !isUser {
                    Text(name(of: message.author)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                if let replyTo = message.replyTo, let answered = messages.first(where: { $0.seq == replyTo }) {
                    quote(answered)
                }
                if isUser { userBubble } else { agentBubble }
                Text(Date(timeIntervalSince1970: message.at / 1000), format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if !isUser { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("room-message-\(message.seq)")
    }

    /// "↩︎ Julián: …": the message this one answers, in a line.
    private func quote(_ answered: AgentRoomMessage) -> some View {
        let prose = MarkdownSegments.cached(answered.text).compactMap { segment -> String? in
            if case .prose(let text) = segment { return text }
            return nil
        }.joined(separator: " ")
        return Text("↩︎ \(name(of: answered.author)): \(prose.replacingOccurrences(of: "\n", with: " "))")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 280, alignment: isUser ? .trailing : .leading)
    }

    private var userBubble: some View {
        var text = AttributedString(message.text)
        for range in AgentRoom.mentionRanges(in: message.text, members: room.members) {
            if let lower = AttributedString.Index(range.lowerBound, within: text), let upper = AttributedString.Index(range.upperBound, within: text) {
                text[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            }
        }
        return Text(text)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(Color.white)
            .background(Color.userBubble, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var agentBubble: some View {
        let segments = MarkdownSegments.cached(message.text)
        let content = segments.compactMap { segment -> MarkdownSegments.Segment? in
            switch segment {
            case .options: nil
            case .prose(let text): .prose(boldMentions(text))
            default: segment
            }
        }
        let options = segments.flatMap { segment -> [String] in if case .options(let items) = segment { items } else { [] } }
        if !content.isEmpty {
            MarkdownText(segments: content)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.agentBubble, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        if !options.isEmpty {
            ReplyOptions(options: options, chosen: AgentRoom.chosenOption(on: message, options: options, messages: messages), onSelect: pick)
                .accessibilityIdentifier("room-options-\(message.seq)")
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

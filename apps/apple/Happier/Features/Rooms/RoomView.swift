import HappierKit
import SwiftUI

/// A room's chat: who said what, oldest first; the agents replying now; the members another agent
/// mentioned that wait for you ("Let … Answer"); the brake after six agent turns in a row; and the
/// pause. Your message reaches the members you mention with @; with no one mentioned, the last agent
/// who spoke is suggested. Delivery is the members' daemons' (`decideRoomDelivery`).
struct RoomView: View {
    let roomId: String
    @Environment(HappierStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    @State private var sending = false
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
    }

    private func chat(_ room: AgentRoom) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if messages.isEmpty {
                        Text("Mention an agent with @ to start: \(room.members.compactMap(\.name).map { "@\($0)" }.joined(separator: ", ")).")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(messages) { message in
                        RoomMessageRow(message: message, room: room).id(message.seq)
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
            if let partial = partialMention(), !suggestions(room, partial).isEmpty {
                // Completing the @ being typed.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions(room, partial)) { member in
                            Button("@\(member.name ?? member.agentId)") { complete(partial, with: member) }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                        }
                    }
                }
            } else if !typed.isEmpty, mentioned.isEmpty, let last = AgentRoom.lastAgentSpeaker(messages),
                      let member = room.members.first(where: { $0.agentId == last }) {
                // Without @ it reaches no one: the last agent who spoke is suggested.
                HStack(spacing: 6) {
                    Text("No one is mentioned.").font(.caption).foregroundStyle(.secondary)
                    Button("Mention @\(member.name ?? member.agentId)") {
                        draft = "@\(member.name ?? member.agentId) " + draft
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .accessibilityIdentifier("room-suggest-mention")
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message the room · @ to mention", text: $draft, axis: .vertical)
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

    /// The `@word` being typed at the end of the draft, without the `@`.
    private func partialMention() -> String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at > draft.startIndex, let before = draft[..<at].last, before.isLetter || before.isNumber { return nil }
        let word = draft[draft.index(after: at)...]
        return word.contains(where: \.isWhitespace) ? nil : String(word)
    }

    private func suggestions(_ room: AgentRoom, _ partial: String) -> [AgentRoom.Member] {
        room.members.filter { member in
            guard let name = member.name else { return false }
            return partial.isEmpty || name.range(of: partial, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
        }
        .filter { member in member.name.map { "@\($0)".caseInsensitiveCompare("@\(partial)") != .orderedSame } ?? false }
    }

    private func complete(_ partial: String, with member: AgentRoom.Member) {
        guard let at = draft.lastIndex(of: "@") else { return }
        draft = String(draft[..<at]) + "@\(member.name ?? member.agentId) "
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

/// One message: yours on the right in your color; an agent's on the left under its emoji and name.
private struct RoomMessageRow: View {
    let message: AgentRoomMessage
    let room: AgentRoom
    @Environment(HappierStore.self) private var store

    private var isUser: Bool { message.author == .user }

    private var authorName: String {
        switch message.author {
        case .user: return room.userName ?? String(localized: "You")
        case .agent(let id, let name, _, _): return name ?? room.members.first { $0.agentId == id }?.name ?? id
        }
    }

    private var emoji: String? {
        if case .agent(let id, _, let emoji, _) = message.author { return emoji ?? room.members.first { $0.agentId == id }?.emoji }
        return nil
    }

    private var providerId: String? {
        message.author.agentId.flatMap { store.agentProfile(id: $0)?.providerId }
    }

    private var text: AttributedString {
        (try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(message.text)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 48) }
            if !isUser {
                AgentAvatar(agentId: providerId, size: 28, emoji: emoji)
            }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                if !isUser {
                    Text(authorName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(isUser ? Color.white : Color.primary)
                    .background(isUser ? AnyShapeStyle(Color.userBubble) : AnyShapeStyle(Color.primary.opacity(0.07)),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text(Date(timeIntervalSince1970: message.at / 1000), format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if !isUser { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("room-message-\(message.seq)")
    }
}

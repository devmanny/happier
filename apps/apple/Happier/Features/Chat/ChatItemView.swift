import HappierKit
import SwiftUI

struct ChatItemView: View {
    let item: ChatItem
    let sessionId: String
    let tail: Bool

    var body: some View {
        switch item {
        case .userText(let message):
            UserBubble(message: message, tail: tail, sessionId: sessionId)
        case .agentText(let message):
            if message.isThinking {
                ThinkingRow(message: message)
            } else {
                AgentBubble(itemId: message.id, text: message.text, date: message.createdAt, seq: message.seq, tail: tail, sessionId: sessionId)
            }
        case .toolCall(let tool):
            ToolCallCard(tool: tool, sessionId: sessionId)
        case .event(let event):
            EventRow(event: event)
        }
    }
}

private struct UserBubble: View {
    let message: UserText
    let tail: Bool
    let sessionId: String
    @Environment(HappierStore.self) private var store

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            let previews = message.attachments.compactMap(AttachmentPreviews.cached)
            if !previews.isEmpty {
                HStack(spacing: 6) {
                    Spacer(minLength: 56)
                    ForEach(Array(previews.enumerated()), id: \.offset) { _, preview in
                        PreviewTile(preview: preview, size: previews.count == 1 ? 180 : 110)
                    }
                }
            }
            let unpreviewed = message.attachments.filter { AttachmentPreviews.cached($0) == nil }
            if !message.text.isEmpty || !unpreviewed.isEmpty {
                HStack {
                    Spacer(minLength: 56)
                    VStack(alignment: .leading, spacing: 6) {
                        if !message.text.isEmpty {
                            Text(message.text)
                                .textSelection(.enabled)
                        }
                        ForEach(unpreviewed, id: \.self) { name in
                            Label(name, systemImage: "paperclip")
                                .font(.footnote.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .foregroundStyle(.white)
                    .bubblePadding(fromUser: true)
                    .background(Color.userBubble, in: BubbleShape(fromUser: true, tail: tail))
                    .messageActions(text: message.text, date: message.createdAt, shape: BubbleShape(fromUser: true, tail: tail), selectionId: message.id,
                                    target: message.seq.map { MessageTarget(sessionId: sessionId, seq: $0, role: .user) })
                    .opacity(message.isPending ? 0.7 : 1)
                }
            }
            if message.isPending {
                if let progress = message.localId.flatMap({ store.uploadProgress[$0] }) {
                    // Attachments still uploading to the computer.
                    HStack(spacing: 6) {
                        ProgressView(value: progress.fraction)
                            .frame(width: 80)
                            .tint(Color.userBubble)
                        Text("Uploading \(progress.fraction, format: .percent.precision(.fractionLength(0)))")
                            .monospacedDigit()
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)
                } else {
                    Text(message.attachments.isEmpty ? "Queued" : "Sending…")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 6)
                }
            }
        }
    }
}

private struct AgentBubble: View {
    let itemId: String
    let text: String
    let date: Date
    let seq: Int?
    let tail: Bool
    let sessionId: String
    @Environment(HappierStore.self) private var store

    var body: some View {
        let segments = MarkdownSegments.parse(text)
        let content = segments.filter { if case .options = $0 { false } else { true } }
        let options: [String] = segments.flatMap { segment -> [String] in if case .options(let items) = segment { items } else { [] } }
        VStack(alignment: .leading, spacing: 6) {
            if !content.isEmpty {
                HStack {
                    MarkdownText(segments: content)
                        .bubblePadding(fromUser: false)
                        .background(Color.agentBubble, in: BubbleShape(fromUser: false, tail: tail && options.isEmpty))
                        .messageActions(text: text, date: date, shape: BubbleShape(fromUser: false, tail: tail && options.isEmpty), selectionId: itemId,
                                        target: seq.map { MessageTarget(sessionId: sessionId, seq: $0, role: .assistant) })
                    Spacer(minLength: 40)
                }
            }
            if !options.isEmpty {
                ReplyOptions(options: options) { option in
                    Task { await store.send(option, to: sessionId) }
                }
            }
        }
    }
}

/// `<options>` reply suggestions: tap sends the text as your message, long-press copies it.
private struct ReplyOptions: View {
    let options: [String]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(options, id: \.self) { option in
                Button {
                    #if os(iOS)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    #endif
                    onSelect(option)
                } label: {
                    Text(option)
                        .font(.callout.weight(.medium))
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .foregroundStyle(Color.userBubble)
                        .background(Color.userBubble.opacity(0.1), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.userBubble.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") { MessageClipboard.copy(option) }
                }
                .accessibilityHint("Sends this reply")
            }
        }
        .padding(.leading, 4)
    }
}

private struct ThinkingRow: View {
    let message: AgentText
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.smooth) { expanded.toggle() }
            } label: {
                Label("Thought process", systemImage: "brain")
                    .font(.footnote.weight(.medium))
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            if expanded {
                Text(message.text)
                    .font(.footnote)
                    .italic()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

private struct EventRow: View {
    let event: TranscriptEvent

    var body: some View {
        Text(label)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    private var label: String {
        switch event.kind {
        case "switch":
            event.data["mode"]?.stringValue == "local" ? String(localized: "Continued on the computer") : String(localized: "Continued remotely")
        case "message":
            event.data["message"]?.stringValue ?? ""
        case "limit-reached":
            String(localized: "Usage limit reached")
        case "context-compaction":
            String(localized: "Context compacted")
        default:
            event.kind.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }
}

// MARK: - Message actions (long press)

/// Identifies a committed transcript message for Pin / Fork / Restore.
struct MessageTarget {
    let sessionId: String
    let seq: Int
    let role: MessagePins.Role
}

private struct MessageActionsModifier: ViewModifier {
    let text: String
    let date: Date
    let shape: BubbleShape
    let selectionId: String?
    let target: MessageTarget?
    @Environment(HappierStore.self) private var store
    @Environment(\.beginMessageSelection) private var beginSelection

    func body(content: Content) -> some View {
        let pinned = target.map { store.pins.isPinned(sessionId: $0.sessionId, seq: $0.seq) } ?? false
        content
            #if os(iOS)
            .contentShape(.contextMenuPreview, shape)
            #endif
            .overlay(alignment: target?.role == .user ? .topLeading : .topTrailing) {
                if pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(4)
                        .background(.background, in: Circle())
                        .offset(x: target?.role == .user ? -8 : 8, y: -8)
                        .accessibilityLabel("Pinned")
                }
            }
            .contextMenu {
                Section(date.formatted(date: .abbreviated, time: .shortened)) {
                    Button("Copy", systemImage: "doc.on.doc") { MessageClipboard.copy(text) }
                    let speaking = MessageSpeaker.shared.isSpeaking(text)
                    Button(speaking ? "Stop Speaking" : "Speak", systemImage: speaking ? "stop.circle" : "speaker.wave.2") {
                        MessageSpeaker.shared.toggle(text)
                    }
                    if let selectionId, let beginSelection {
                        Button("Select", systemImage: "checkmark.circle") { beginSelection(selectionId) }
                    }
                    if let target {
                        Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                            store.togglePin(sessionId: target.sessionId, seq: target.seq, role: target.role)
                        }
                        if target.seq > 0 {
                            Button("Fork from Here", systemImage: "arrow.triangle.branch") {
                                // A forked user message comes back as the new session's draft (seq >= 2).
                                let restored = target.role == .user && target.seq >= 2 ? text : nil
                                Task { await store.fork(target.sessionId, upToSeq: target.seq, restoring: restored) }
                            }
                        }
                        if target.role == .user, store.sessions[target.sessionId]?.canRollback(toUserMessageSeq: target.seq) == true {
                            Button("Restore to Here", systemImage: "arrow.uturn.backward", role: .destructive) {
                                Task { await store.rollback(target.sessionId, toUserMessageSeq: target.seq, restoring: text) }
                            }
                        }
                    }
                }
            }
    }
}

extension View {
    /// Long-press "pop" with the message's date/time and its actions.
    func messageActions(text: String, date: Date, shape: BubbleShape, selectionId: String? = nil, target: MessageTarget? = nil) -> some View {
        modifier(MessageActionsModifier(text: text, date: date, shape: shape, selectionId: selectionId, target: target))
    }
}

enum MessageClipboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

extension EnvironmentValues {
    /// Enters message selection with the given transcript item preselected (set by the chat).
    @Entry var beginMessageSelection: ((String) -> Void)? = nil
}

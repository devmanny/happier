import HappierKit
import SwiftUI

struct ChatItemView: View {
    let item: ChatItem
    let sessionId: String
    let tail: Bool

    var body: some View {
        switch item {
        case .userText(let message):
            if let origin = message.sessionMessageOrigin {
                SessionActivityRow(messageText: message.text, origin: origin, itemId: message.id, sessionId: sessionId,
                                   date: message.createdAt, transportStatus: message.isPending ? String(localized: "Queued") : nil)
            } else if let notice = message.sessionNotice {
                SessionActivityRow(notice: notice, itemId: message.id, sessionId: sessionId, date: message.createdAt,
                                   transportStatus: message.isPending ? String(localized: "Queued") : nil)
            } else {
                UserBubble(message: message, tail: tail, sessionId: sessionId)
            }
        case .agentText(let message):
            if message.isThinking {
                ThinkingRow(message: message)
            } else {
                AgentBubble(itemId: message.id, text: message.text, date: message.createdAt, seq: message.seq, tail: tail, sessionId: sessionId)
            }
        case .toolCall(let tool):
            if let sent = tool.sentFiles {
                SentFilesView(sent: sent, sessionId: sessionId, tail: tail)
            } else {
                ToolCallCard(tool: tool, sessionId: sessionId)
            }
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
    @Environment(\.openSessionFilePreview) private var openFilePreview
    @Environment(\.userBubbleColor) private var bubbleColor

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            // Sent files carry where they live (and maybe a preview); a message still being sent
            // only has this device's names and previews.
            let files = message.files.isEmpty ? message.attachments.map { MessageAttachment(name: $0) } : message.files
            let media = files.filter { $0.isImage || $0.isVideo || AttachmentPreviews.cached($0.name) != nil }
            if !media.isEmpty {
                MessageAttachmentTiles(files: media, sessionId: sessionId, fromUser: true) { openFilePreview?($0) }
            }
            let unpreviewed = files.filter { file in !media.contains { $0.id == file.id } }
            if !message.text.isEmpty || !unpreviewed.isEmpty {
                HStack {
                    Spacer(minLength: 56)
                    VStack(alignment: .leading, spacing: 6) {
                        if !message.text.isEmpty {
                            // Your Markdown renders like the agent's, in the bubble's light-on-blue
                            // palette (dark code blocks and tables, white links).
                            MarkdownText(message.text)
                                .environment(\.colorScheme, .dark)
                                .tint(.white)
                        }
                        ForEach(unpreviewed) { file in
                            MessageAttachmentChip(file: file, sessionId: sessionId) { openFilePreview?($0) }
                        }
                    }
                    .foregroundStyle(.white)
                    .bubblePadding(fromUser: true)
                    .background(bubbleColor, in: BubbleShape(fromUser: true, tail: tail))
                    .messageActions(text: message.text, date: message.createdAt, shape: BubbleShape(fromUser: true, tail: tail), selectionId: message.id,
                                    target: message.seq.map { MessageTarget(sessionId: sessionId, seq: $0, role: .user) })
                    .selectableMessage(id: message.id, markdown: message.text, fromUser: true, shape: BubbleShape(fromUser: true, tail: tail))
                    .opacity(message.isPending ? 0.7 : 1)
                }
            }
            if message.isPending {
                if let localId = message.localId, let error = store.failedSends[localId] {
                    VStack(alignment: .trailing, spacing: 5) {
                        Label("Not sent", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                        Text(error)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                        HStack(spacing: 8) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                AppHaptics.warning()
                                withAnimation(.smooth(duration: 0.2)) { store.discardFailedSend(localId, in: sessionId) }
                            }
                            .accessibilityIdentifier("discard-send-\(localId)")
                            Button("Retry", systemImage: "arrow.clockwise") {
                                AppHaptics.confirm()
                                Task { await store.retrySend(localId, in: sessionId) }
                            }
                            .accessibilityIdentifier("retry-send-\(localId)")
                        }
                        .buttonStyle(.bordered)
                    }
                    .font(.caption)
                    .padding(.leading, 56)
                    .padding(.trailing, 6)
                } else if let progress = message.localId.flatMap({ store.uploadProgress[$0] }) {
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
        let segments = MarkdownSegments.cached(text)
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
                        .selectableMessage(id: itemId, markdown: text, fromUser: false, shape: BubbleShape(fromUser: false, tail: tail && options.isEmpty))
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

/// `<options>` reply suggestions: tap sends the text as your message; drag one into the composer
/// (or pick "Edit before sending") to change it first; long-press also copies it. In a room, the
/// one already picked (`chosen`) is marked and the rest can't be picked again.
struct ReplyOptions: View {
    let options: [String]
    var chosen: String? = nil
    let onSelect: (String) -> Void
    @Environment(\.chatRowActions) private var rowActions
    @Environment(\.userBubbleColor) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(options, id: \.self) { option in
                Button {
                    AppHaptics.confirm()
                    onSelect(option)
                } label: {
                    Group {
                        if option == chosen {
                            Label { pill(option) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) }
                        } else {
                            pill(option)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(accent.opacity(0.2), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(accent.opacity(0.55), lineWidth: 1) }
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(chosen != nil)
                .opacity(chosen != nil && option != chosen ? 0.45 : 1)
                // Drawn by hand in the conversation's color under plain text: the Mac's glass shows
                // no tint, and colored text on it was too faint to read.
                .buttonStyle(.pressable)
                .onDrag {
                    rowActions?.replyDragStarted(option)
                    return NSItemProvider(object: option as NSString)
                } preview: {
                    pill(option)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                }
                .contextMenu {
                    if let rowActions {
                        Button("Edit before Sending", systemImage: "pencil") { AppHaptics.light(); rowActions.editInComposer(option) }
                    }
                    Button("Copy", systemImage: "doc.on.doc") { MessageClipboard.copy(option); AppHaptics.success() }
                }
                .accessibilityHint("Sends this reply")
            }
        }
        .padding(.leading, 4)
    }

    private func pill(_ option: String) -> some View {
        Text(option)
            .font(.callout.weight(.medium))
            .multilineTextAlignment(.leading)
            .foregroundStyle(.primary)
    }
}

private struct ThinkingRow: View {
    let message: AgentText
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The same line as a tool call or a work summary: icon, caption, chevron.
            Button {
                AppHaptics.light()
                withAnimation(.smooth(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.caption2)
                        .frame(width: 14)
                    Text("Thought process")
                        .font(.caption.weight(.medium))
                    DisclosureChevron(expanded: expanded)
                    Spacer(minLength: 4)
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 3)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityHint(expanded ? "Hides the thought process" : "Shows the thought process")
            if expanded {
                Text(message.text)
                    .font(.footnote)
                    .italic()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 24)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.trailing, 40)
    }
}

private struct EventRow: View {
    let event: TranscriptEvent

    var body: some View {
        Group {
            if event.kind == "local-command" {
                // A command run in Claude Code ("Model: Opus 5.5", "/mcp"): a system line, not a message.
                Label(event.data["text"]?.stringValue ?? "", systemImage: "terminal")
                    .lineLimit(2)
                    .accessibilityLabel(Text("Command: \(event.data["text"]?.stringValue ?? "")"))
            } else if event.kind == "runtime-config-outcome" {
                // "Model changed to … · Effort High · 4:12 PM": when it changed.
                Text("\(label) · \(event.createdAt, format: .dateTime.hour().minute())")
            } else {
                Text(label)
            }
        }
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
        case "message", "runtime-config-outcome":
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
    @Environment(\.chatRowActions) private var rowActions

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
                    Button("Copy", systemImage: "doc.on.doc") { MessageClipboard.copy(text); AppHaptics.success() }
                    let speaking = MessageSpeaker.shared.isSpeaking(text)
                    Button(speaking ? "Stop Speaking" : "Speak", systemImage: speaking ? "stop.circle" : "speaker.wave.2") {
                        AppHaptics.light()
                        MessageSpeaker.shared.toggle(text, sessionId: target?.sessionId)
                    }
                    if let selectionId, let rowActions {
                        Button("Select Text", systemImage: "text.cursor") { rowActions.beginTextSelection(selectionId) }
                    }
                    if let selectionId, let rowActions {
                        Button("Select", systemImage: "checkmark.circle") { rowActions.beginMessageSelection(selectionId) }
                    }
                    if let target {
                        Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                            AppHaptics.selection()
                            store.togglePin(sessionId: target.sessionId, seq: target.seq, role: target.role)
                        }
                        if target.seq > 0 {
                            Button("Fork from Here", systemImage: "arrow.triangle.branch") {
                                AppHaptics.confirm()
                                // A forked user message comes back as the new session's draft (seq >= 2).
                                let restored = target.role == .user && target.seq >= 2 ? text : nil
                                Task { await store.fork(target.sessionId, upToSeq: target.seq, restoring: restored) }
                            }
                        }
                        if target.role == .user, store.sessions[target.sessionId]?.canRollback(toUserMessageSeq: target.seq) == true {
                            Button("Restore to Here", systemImage: "arrow.uturn.backward", role: .destructive) {
                                AppHaptics.warning()
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

/// What a conversation's rows can ask of it: one object per conversation, made once. Closures
/// handed down through the environment were new on every redraw of the conversation (a closure is
/// never equal to another), so every row re-ran on every streamed update even when only one
/// changed; this object keeps its identity, so the environment stays the same.
@MainActor
final class ChatRowActions {
    /// Enters message selection with the given transcript item preselected.
    var beginMessageSelection: (String) -> Void = { _ in }
    /// Puts text in the composer to edit before sending.
    var editInComposer: (String) -> Void = { _ in }
    /// Opens a message's text for selecting.
    var beginTextSelection: (String) -> Void = { _ in }
    /// Where the message being selected sits on screen, so a tap elsewhere can close it.
    var reportTextSelectionFrame: (CGRect) -> Void = { _ in }
    /// A reply suggestion started being dragged (a drop anywhere on the conversation lands it in
    /// the composer instead of attaching it as a file).
    var replyDragStarted: (String) -> Void = { _ in }
}

extension EnvironmentValues {
    /// The open conversation's row actions (set by the chat; nil elsewhere).
    @Entry var chatRowActions: ChatRowActions? = nil
}

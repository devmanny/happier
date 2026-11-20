import HappierKit
import SwiftUI

/// A message waiting in the server queue. Tap opens the same actions as the RN pending block
/// (`PendingMessagesTranscriptBlock.tsx`): Steer now, Send now (interrupt), Edit, Remove, Copy —
/// or Re-queue / Steer now / Send now / Copy / Remove for discarded ones. One already being
/// delivered can only be copied; one the agent may already have can be sent again or removed.
struct PendingBubble: View {
    let message: PendingMessage
    let sessionId: String
    let working: Bool
    @Environment(HappierStore.self) private var store
    /// The conversation's bubble color (its project folder's), as for sent messages.
    @Environment(\.userBubbleColor) private var bubbleColor
    @State private var showActions = false
    @State private var confirmSendNow = false
    @State private var editing = false
    @State private var editText = ""

    private var session: Session? { store.sessions[sessionId] }
    private var canSteerNow: Bool { working && (session?.steerAvailable ?? false) }

    var body: some View {
        Group {
            if let origin = message.sessionMessageOrigin {
                SessionActivityRow(messageText: message.text, origin: origin, itemId: UserText.stableId(localId: message.localId),
                                   sessionId: sessionId, date: message.createdAt, transportStatus: statusLabel,
                                   transportStatusIsBlocked: isBlocked) {
                    activityActions(prefix: "session-message")
                }
            } else if let notice = message.sessionNotice {
                SessionActivityRow(notice: notice, itemId: UserText.stableId(localId: message.localId), sessionId: sessionId, date: message.createdAt,
                                   transportStatus: statusLabel, transportStatusIsBlocked: isBlocked) {
                    activityActions(prefix: "session-notice")
                }
            } else {
                userBubble
            }
        }
        .confirmationDialog(actionsTitle,
                            isPresented: $showActions, titleVisibility: .visible) {
            actions
            // iOS adds its own; on the Mac this is the way out (and what Esc does).
            Button("Cancel", role: .cancel) {}
        } message: {
            if message.state == .delivering {
                Text("It's on its way to the agent and can't be changed now.")
            } else if case .uncertain = message.state {
                Text("The connection to the agent dropped while this was being delivered, so it may or may not have arrived. Send it again if the agent didn't get it, or remove it if it did.")
            }
        }
        .alert(sendNowTitle, isPresented: $confirmSendNow) {
            Button("Send Now", role: .destructive) {
                AppHaptics.warning()
                Task {
                    if message.state == .discarded {
                        await store.restoreAndSend(message.localId, action: .sendNow, in: sessionId)
                    } else {
                        await store.sendPendingNow(message.localId, in: sessionId)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will stop the current turn and send this message immediately.")
        }
        .alert("Edit Pending Message", isPresented: $editing) {
            TextField("Message", text: $editText, axis: .vertical)
            Button("Save") {
                let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                AppHaptics.confirm()
                Task { await store.editPending(message.localId, text: text, in: sessionId) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var actionsTitle: String {
        if message.sessionMessageOrigin != nil { return String(localized: "Session Message") }
        if message.sessionNotice != nil { return String(localized: "Automatic Notice") }
        return message.text
    }

    private func activityActions(prefix: String) -> some View {
        Button("More Actions", systemImage: "ellipsis.circle") {
            AppHaptics.light()
            showActions = true
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .frame(minHeight: 44, alignment: .leading)
        .contextMenu { actions }
        .accessibilityIdentifier("\(prefix)-actions-\(message.localId)")
    }

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack {
                Spacer(minLength: 56)
                // Your Markdown, as in sent messages (light on blue).
                MarkdownText(message.text)
                    .environment(\.colorScheme, .dark)
                    .tint(.white)
                    .foregroundStyle(.white)
                    .bubblePadding(fromUser: true)
                    .background(bubbleColor.opacity(message.state == .discarded ? 0.35 : 0.55),
                                in: BubbleShape(fromUser: true, tail: true))
                    .onTapGesture { AppHaptics.light(); showActions = true }
                    .contextMenu { actions }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Shows actions for this queued message")
            }
            Text(statusLabel)
                .font(.caption2.weight(.medium))
                .foregroundStyle(isBlocked ? Color.orange : Color.secondary)
                .padding(.trailing, 6)
        }
    }

    @ViewBuilder private var actions: some View {
        switch message.state {
        case .discarded:
            Button("Re-queue") { AppHaptics.confirm(); Task { await store.requeuePending(message.localId, in: sessionId) } }
            if canSteerNow {
                Button("Steer Now") { AppHaptics.confirm(); Task { await store.restoreAndSend(message.localId, action: .steerNow, in: sessionId) } }
            }
            Button(sendNowLabel) { AppHaptics.light(); confirmSendNow = true }
            Button("Copy") { MessageClipboard.copy(message.text); AppHaptics.success() }
            Button("Remove", role: .destructive) { AppHaptics.warning(); Task { await store.removePending(message.localId, in: sessionId) } }
        case .blocked(let reason):
            if reason == Self.terminalNotReady {
                // A plain retry goes back to the terminal that never came up.
                Button("Restart Session & Retry") {
                    AppHaptics.confirm()
                    Task { await store.restartSessionAndRetry(message.localId, in: sessionId) }
                }
                .disabled(store.restartingSessions.contains(sessionId))
            }
            Button("Retry") { AppHaptics.confirm(); Task { await store.requeuePending(message.localId, in: sessionId) } }
            Button(sendNowLabel) { AppHaptics.light(); confirmSendNow = true }
            Button("Edit") { AppHaptics.light(); beginEdit() }
            Button("Copy") { MessageClipboard.copy(message.text); AppHaptics.success() }
            Button("Remove", role: .destructive) { AppHaptics.warning(); Task { await store.removePending(message.localId, in: sessionId) } }
        case .uncertain:
            // The server refuses ordinary changes now; only its delivery resolutions apply.
            Button("Send Again") { AppHaptics.confirm(); Task { await store.sendPendingAgain(message.localId, in: sessionId) } }
            Button("Copy") { MessageClipboard.copy(message.text); AppHaptics.success() }
            Button("Remove", role: .destructive) { AppHaptics.warning(); Task { await store.removePending(message.localId, in: sessionId) } }
        case .delivering:
            // The runner has taken it; the server refuses changes from here on (no double send).
            Button("Copy") { MessageClipboard.copy(message.text); AppHaptics.success() }
        case .queued:
            if canSteerNow {
                Button("Steer Now") { AppHaptics.confirm(); Task { await store.steerPendingNow(message.localId, in: sessionId) } }
            }
            Button(sendNowLabel) { AppHaptics.light(); confirmSendNow = true }
            Button("Edit") { AppHaptics.light(); beginEdit() }
            Button("Copy") { MessageClipboard.copy(message.text); AppHaptics.success() }
            Button("Remove", role: .destructive) { AppHaptics.warning(); Task { await store.removePending(message.localId, in: sessionId) } }
        }
    }

    private func beginEdit() {
        editText = message.text
        editing = true
    }

    private var isBlocked: Bool {
        switch message.state {
        case .blocked, .uncertain: true
        default: false
        }
    }

    private var sendNowLabel: LocalizedStringKey { working ? "Send Now (Interrupt)" : "Send Now" }
    private var sendNowTitle: LocalizedStringKey { working ? "Send now (interrupt)?" : "Send now?" }

    private var statusLabel: String {
        switch message.state {
        case .queued: working ? String(localized: "Queued · waiting for the current turn") : String(localized: "Queued")
        case .delivering: String(localized: "Delivering…")
        case .discarded: String(localized: "Discarded")
        case .blocked where store.restartingSessions.contains(sessionId): String(localized: "Restarting the session…")
        case .blocked(let reason): String(localized: "Blocked · \(Self.reasonLabel(reason))")
        case .uncertain: String(localized: "Not sure it reached the agent")
        }
    }

    /// The runner gave up starting its terminal (`terminal_host_unreachable`).
    static let terminalNotReady = "terminal_host_unreachable"

    static func reasonLabel(_ reason: String) -> String {
        switch reason {
        case "steering_unavailable": String(localized: "steering unavailable")
        case "terminal_composer_draft": String(localized: "a draft is open in the terminal")
        case "payload_too_large": String(localized: "message too large")
        case terminalNotReady: String(localized: "the agent’s terminal didn’t start")
        default: reason.replacingOccurrences(of: "_", with: " ")
        }
    }
}

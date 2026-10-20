import HappierKit
import SwiftUI

/// A message waiting in the server queue. Tap opens the same actions as the RN pending block
/// (`PendingMessagesTranscriptBlock.tsx`): Steer now, Send now (interrupt), Edit, Remove, Copy —
/// or Re-queue / Steer now / Send now / Copy / Remove for discarded ones.
struct PendingBubble: View {
    let message: PendingMessage
    let sessionId: String
    let working: Bool
    @Environment(HappierStore.self) private var store
    @State private var showActions = false
    @State private var confirmSendNow = false
    @State private var editing = false
    @State private var editText = ""

    private var session: Session? { store.sessions[sessionId] }
    private var canSteerNow: Bool { working && (session?.steerAvailable ?? false) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack {
                Spacer(minLength: 56)
                Text(message.text)
                    .foregroundStyle(.white)
                    .bubblePadding(fromUser: true)
                    .background(Color.userBubble.opacity(message.state == .discarded ? 0.35 : 0.55),
                                in: BubbleShape(fromUser: true, tail: true))
                    .onTapGesture { showActions = true }
                    .contextMenu { actions }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Shows actions for this queued message")
            }
            Text(statusLabel)
                .font(.caption2.weight(.medium))
                .foregroundStyle(isBlocked ? Color.orange : Color.secondary)
                .padding(.trailing, 6)
        }
        .confirmationDialog(message.text, isPresented: $showActions, titleVisibility: .visible) { actions }
        .alert(sendNowTitle, isPresented: $confirmSendNow) {
            Button("Send Now", role: .destructive) {
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
                Task { await store.editPending(message.localId, text: text, in: sessionId) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private var actions: some View {
        switch message.state {
        case .discarded:
            Button("Re-queue") { Task { await store.requeuePending(message.localId, in: sessionId) } }
            if canSteerNow {
                Button("Steer Now") { Task { await store.restoreAndSend(message.localId, action: .steerNow, in: sessionId) } }
            }
            Button(sendNowLabel) { confirmSendNow = true }
            Button("Copy") { MessageClipboard.copy(message.text) }
            Button("Remove", role: .destructive) { Task { await store.removePending(message.localId, in: sessionId) } }
        case .blocked:
            Button("Retry") { Task { await store.requeuePending(message.localId, in: sessionId) } }
            Button(sendNowLabel) { confirmSendNow = true }
            Button("Edit") { beginEdit() }
            Button("Copy") { MessageClipboard.copy(message.text) }
            Button("Remove", role: .destructive) { Task { await store.removePending(message.localId, in: sessionId) } }
        case .queued, .delivering:
            if canSteerNow {
                Button("Steer Now") { Task { await store.steerPendingNow(message.localId, in: sessionId) } }
            }
            Button(sendNowLabel) { confirmSendNow = true }
            Button("Edit") { beginEdit() }
            Button("Copy") { MessageClipboard.copy(message.text) }
            Button("Remove", role: .destructive) { Task { await store.removePending(message.localId, in: sessionId) } }
        }
    }

    private func beginEdit() {
        editText = message.text
        editing = true
    }

    private var isBlocked: Bool { if case .blocked = message.state { true } else { false } }

    private var sendNowLabel: LocalizedStringKey { working ? "Send Now (Interrupt)" : "Send Now" }
    private var sendNowTitle: LocalizedStringKey { working ? "Send now (interrupt)?" : "Send now?" }

    private var statusLabel: String {
        switch message.state {
        case .queued: working ? String(localized: "Queued · waiting for the current turn") : String(localized: "Queued")
        case .delivering: String(localized: "Delivering…")
        case .discarded: String(localized: "Discarded")
        case .blocked(let reason): String(localized: "Blocked · \(Self.reasonLabel(reason))")
        }
    }

    static func reasonLabel(_ reason: String) -> String {
        switch reason {
        case "steering_unavailable": String(localized: "steering unavailable")
        case "terminal_composer_draft": String(localized: "a draft is open in the terminal")
        case "payload_too_large": String(localized: "message too large")
        default: reason.replacingOccurrences(of: "_", with: " ")
        }
    }
}

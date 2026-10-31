import HappierKit
import SwiftUI

/// What's waiting for you, then who's working; a session opens its last words and your answer.
struct HomeView: View {
    @Environment(PhoneLink.self) private var phone
    @State private var newSession = false

    var body: some View {
        List {
            if phone.attention.isEmpty, phone.working.isEmpty {
                ContentUnavailableView {
                    Label(phone.context == nil ? "Open Happier on your iPhone" : "All caught up", systemImage: phone.context == nil ? "iphone" : "checkmark.circle.fill")
                } description: {
                    Text(phone.context == nil ? "The watch shows what the iPhone app sees." : "Nothing is waiting for you.")
                }
                .listRowBackground(Color.clear)
            }
            if !phone.attention.isEmpty {
                Section("Needs You") {
                    ForEach(phone.attention) { item in
                        NavigationLink(value: item.sessionId) { AttentionRow(item: item) }
                    }
                }
            }
            if !phone.working.isEmpty {
                Section("Working") {
                    ForEach(phone.working) { item in
                        HStack(spacing: 8) {
                            AgentBadge(agentId: item.agentId, size: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).font(.footnote.weight(.semibold)).lineLimit(1)
                                Text(item.since, style: .timer).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Happier")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { newSession = true } label: { Label("New Session", systemImage: "plus.bubble.fill") }
            }
        }
        .sheet(isPresented: $newSession) { NewSessionSheet() }
    }
}

private struct AttentionRow: View {
    let item: AttentionSnapshot.Item

    var body: some View {
        HStack(spacing: 8) {
            AgentBadge(agentId: item.agentId, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.footnote.weight(.semibold)).lineLimit(1)
                HStack(spacing: 3) {
                    Image(systemName: item.reason == .waitingForYou ? "hand.raised.fill" : "circle.fill")
                        .font(.system(size: item.reason == .waitingForYou ? 9 : 6))
                        .foregroundStyle(item.reason == .waitingForYou ? Color.orange : Color.blue)
                    Text(item.request?.summary ?? (item.reason == .waitingForYou ? "Waiting for you" : "New reply"))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }
}

/// The agent's last words and your answer: Allow or Deny what it asked, or dictate a reply.
struct SessionView: View {
    let sessionId: String
    @Environment(PhoneLink.self) private var phone
    @Environment(\.dismiss) private var dismiss
    @State private var reply = ""
    @State private var sending = false
    @State private var error: String?

    private var item: AttentionSnapshot.Item? { phone.item(sessionId) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let item {
                    HStack(spacing: 6) {
                        AgentBadge(agentId: item.agentId, size: 22)
                        Text(item.title).font(.headline).lineLimit(2)
                    }
                    if let request = item.request {
                        Label(request.summary, systemImage: "hand.raised.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if let words = item.lastAgentText {
                        Text(words).font(.footnote)
                    } else if item.request == nil {
                        Text("A new reply is waiting in the conversation.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error {
                        Text(error).font(.caption2).foregroundStyle(.red)
                    }
                    if phone.handled.contains(sessionId) {
                        Label("Sent", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green)
                    } else if let request = item.request {
                        Button {
                            act(.permission(sessionId: sessionId, requestId: request.id, tool: request.tool, allow: true))
                        } label: { Label("Allow", systemImage: "checkmark") }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                        Button(role: .destructive) {
                            act(.permission(sessionId: sessionId, requestId: request.id, tool: request.tool, allow: false))
                        } label: { Label("Deny", systemImage: "xmark") }
                            .buttonStyle(.bordered)
                    } else {
                        TextField("Reply", text: $reply)
                            .onSubmit { send() }
                        Button { send() } label: { Label("Send", systemImage: "arrow.up.circle.fill") }
                            .buttonStyle(.borderedProminent)
                            .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    ContentUnavailableView("Nothing waiting here", systemImage: "checkmark.circle.fill")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay { if sending { ProgressView().controlSize(.large) } }
        .disabled(sending)
        .navigationTitle(item?.request != nil ? "Approve?" : "Reply")
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        act(.reply(sessionId: sessionId, text: text))
    }

    private func act(_ message: WatchMessage) {
        sending = true
        error = nil
        Task {
            let outcome = await phone.send(message)
            sending = false
            switch outcome {
            case .done:
                reply = ""
                try? await Task.sleep(for: .seconds(0.8))
                dismiss()
            case .failed(let reason):
                error = reason
            }
        }
    }
}

/// Dictate a task; the iPhone starts the session with your usual agent, machine and folder.
struct NewSessionSheet: View {
    @Environment(PhoneLink.self) private var phone
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var starting = false
    @State private var error: String?
    @State private var started = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("What should we work on?").font(.headline)
                TextField("Task", text: $text, axis: .vertical)
                    .onSubmit { start() }
                if let error { Text(error).font(.caption2).foregroundStyle(.red) }
                if started {
                    Label("Started", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green)
                } else {
                    Button { start() } label: { Label("Start", systemImage: "plus.bubble.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay { if starting { ProgressView().controlSize(.large) } }
        .disabled(starting)
        .navigationTitle("New Session")
    }

    private func start() {
        let task = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }
        starting = true
        error = nil
        Task {
            let outcome = await phone.send(.newSession(text: task))
            starting = false
            switch outcome {
            case .done:
                started = true
                try? await Task.sleep(for: .seconds(1))
                dismiss()
            case .failed(let reason):
                error = reason
            }
        }
    }
}

import HappierKit
import SwiftUI

/// The session list's search inside messages: the query goes to every online machine with
/// conversation search on (`HappierStore.searchMessages`), and their results come back merged.
/// While none can answer, the conversations already loaded on this device are searched instead.
@MainActor @Observable
final class MessageSearchResults {
    enum State: Equatable {
        case idle
        case searching
        case results
        /// No online machine has conversation search on; these can turn it on.
        case off([HappierStore.MessageSearchMachine])
        case outdated([String])
        case unavailable
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var hits: [MessageSearch.Hit] = []
    /// Matches in what this device already has, shown while no machine can answer.
    private(set) var localHits: [MessageSearch.Hit] = []
    /// Machines still reading older conversations.
    private(set) var backfilling: [HappierStore.MessageSearchBackfill] = []
    private(set) var cursors: [String: String] = [:]
    private(set) var isLoadingMore = false
    private(set) var turningOn: String?
    private var query = ""

    /// Waits for typing to pause; a newer query cancels this one (the caller's task id).
    static let debounce: Duration = .milliseconds(300)

    /// Whether the section has anything to show for the current query.
    var hasContent: Bool {
        switch state {
        case .idle: false
        case .searching, .off, .outdated, .unavailable, .failed: true
        case .results: !hits.isEmpty || !backfilling.isEmpty
        }
    }

    func update(query next: String, store: HappierStore) async {
        let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= MessageSearch.minimumQueryLength else {
            reset()
            return
        }
        // The previous results stay while the next ones come (no flash of an empty section).
        state = .searching
        try? await Task.sleep(for: Self.debounce)
        guard !Task.isCancelled else { return }
        let outcome = await store.searchMessages(query: trimmed)
        guard !Task.isCancelled else { return }
        query = trimmed
        apply(outcome, store: store, appending: false)
    }

    func loadMore(store: HappierStore) async {
        guard !cursors.isEmpty, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        apply(await store.searchMessages(query: query, cursors: cursors), store: store, appending: true)
    }

    func turnOn(_ machine: HappierStore.MessageSearchMachine, store: HappierStore) async {
        guard turningOn == nil else { return }
        turningOn = machine.id
        defer { turningOn = nil }
        guard await store.setMessageSearch(machineId: machine.id, enabled: true) != nil else { return }
        state = .searching
        apply(await store.searchMessages(query: query), store: store, appending: false)
    }

    private func reset() {
        state = .idle
        hits = []
        localHits = []
        backfilling = []
        cursors = [:]
        query = ""
    }

    private func apply(_ outcome: HappierStore.MessageSearchOutcome, store: HappierStore, appending: Bool) {
        if case .results(let found, let next, let backfilling) = outcome {
            hits = appending ? MessageSearch.merge([hits, found]) : found
            cursors = next
            self.backfilling = backfilling
            localHits = []
            state = .results
            return
        }
        // A failed next page keeps what is already shown.
        if appending {
            cursors = [:]
            return
        }
        switch outcome {
        case .results: return
        case .off(let machines): state = .off(machines)
        case .outdated(let names): state = .outdated(names)
        case .unavailable: state = .unavailable
        case .failed(let message): state = .failed(message)
        }
        hits = []
        cursors = [:]
        backfilling = []
        localHits = store.localMessageHits(query: query)
    }
}

struct MessageSearchSection: View {
    let results: MessageSearchResults
    let open: (MessageSearch.Hit) -> Void
    @Environment(HappierStore.self) private var store

    var body: some View {
        if results.hasContent {
            Section("Messages") {
                status
                ForEach(results.hits) { hit in hitRow(hit) }
                if !results.cursors.isEmpty {
                    Button {
                        Task { await results.loadMore(store: store) }
                    } label: {
                        HStack(spacing: 8) {
                            Text("Show More Messages")
                            if results.isLoadingMore { HappierSpinner(size: HappierSpinner.mini) }
                        }
                    }
                    .disabled(results.isLoadingMore)
                    .accessibilityIdentifier("message-search-more")
                }
                ForEach(results.localHits) { hit in hitRow(hit) }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch results.state {
        case .idle:
            EmptyView()
        case .searching:
            if results.hits.isEmpty {
                Label {
                    Text("Searching messages…").foregroundStyle(.secondary)
                } icon: {
                    HappierSpinner(size: HappierSpinner.mini)
                }
                .font(.subheadline)
            }
        case .results:
            if results.hits.isEmpty {
                Text("No messages match.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(results.backfilling, id: \.machineName) { backfill in
                Label("\(backfill.machineName) is still reading older conversations (\(Int(backfill.coverage.progress * 100)) %).",
                      systemImage: "clock.arrow.circlepath")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .off(let machines):
            VStack(alignment: .leading, spacing: 8) {
                Label("Conversation search is off on your machines.", systemImage: "text.magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                Text("A machine with it on reads every conversation once and keeps a private index on its disk. The relay never sees the text.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(machines, id: \.id) { machine in
                    Button {
                        AppHaptics.light()
                        Task { await results.turnOn(machine, store: store) }
                    } label: {
                        HStack(spacing: 6) {
                            if results.turningOn == machine.id { HappierSpinner(size: HappierSpinner.mini) }
                            Text("Turn On on \(machine.name)")
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .glassHover()
                    .disabled(results.turningOn != nil)
                    .accessibilityIdentifier("message-search-turn-on")
                }
            }
            .padding(.vertical, 4)
            localFallbackNote
        case .outdated(let names):
            Label("Update the Happier CLI on \(names.formatted(.list(type: .and))) to search inside messages.", systemImage: "arrow.down.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            localFallbackNote
        case .unavailable:
            Label("The search Mac isn't available.", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("message-search-unavailable")
            localFallbackNote
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            localFallbackNote
        }
    }

    @ViewBuilder
    private var localFallbackNote: some View {
        if !results.localHits.isEmpty {
            Text("Matches in conversations already on this device:")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func hitRow(_ hit: MessageSearch.Hit) -> some View {
        Button {
            AppHaptics.selection()
            open(hit)
        } label: {
            MessageHitRow(hit: hit, session: store.sessions[hit.sessionId])
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("message-search-hit")
    }
}

/// One message found: the conversation, when the message was written, and the words around the match.
private struct MessageHitRow: View {
    let hit: MessageSearch.Hit
    let session: Session?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(agentId: session?.agentId ?? Agent.id(fromFlavor: hit.agentFlavor))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session?.title ?? hit.title ?? String(localized: "Untitled Session"))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(ChatDate.listLabel(hit.createdAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(snippet)
                    .font(.footnote)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens the conversation at this message"))
    }

    private var snippet: AttributedString {
        var text = AttributedString(hit.fromUser ? String(localized: "You: ") : "")
        text.foregroundColor = .secondary
        for segment in hit.snippet {
            var run = AttributedString(segment.text.replacingOccurrences(of: "\n", with: " "))
            if segment.isMatch {
                run.foregroundColor = .primary
                run.inlinePresentationIntent = .stronglyEmphasized
            } else {
                run.foregroundColor = .secondary
            }
            text += run
        }
        return text
    }
}

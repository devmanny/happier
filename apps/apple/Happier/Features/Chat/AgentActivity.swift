import HappierKit
import SwiftUI

/// Next to the status pill: how many subagents and commands the agent has running in the
/// background. Opens their list.
struct BackgroundActivityPill: View {
    let count: Int
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // White on the blue: a soft tint in dark mode (with a blue robot), solid blue in light mode
        // where white on a pale tint didn't read.
        let light = colorScheme == .light
        Button(action: action) {
            HStack(spacing: 4) {
                RobotIcon(size: 13)
                    .foregroundStyle(light ? Color.white : Color.userBubble)
                Text(count, format: .number)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.white)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            // Not `.interactive()`: interactive glass keeps the tap from reaching the button.
            .glassEffect(.regular.tint(Color.userBubble.opacity(light ? 0.9 : 0.18)), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(Text("\(count) running in the background"))
        .accessibilityHint(Text("Shows the agents and commands"))
        .animation(.smooth(duration: 0.2), value: count)
    }
}

/// The subagents the agent started, the runs delegated from the session through Happier and the
/// commands it left running, newest first: what each one is, whether it is still going, and since
/// when. A subagent opens its own conversation.
struct AgentActivitySheet: View {
    let sessionId: String
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var session: Session? { store.sessions[sessionId] }
    private var subagents: [Subagent] {
        (store.transcripts[sessionId]?.subagents ?? []).reversed().map { $0.settled(by: session) }
    }
    private var commands: [BackgroundCommand] { store.backgroundCommands[sessionId] ?? [] }
    private var runs: [DelegatedRun] { store.delegatedRuns[sessionId] ?? [] }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                List {
                    if !subagents.isEmpty {
                        Section("Subagents") {
                            ForEach(subagents) { subagent in
                                NavigationLink(value: subagent) {
                                    SubagentRow(subagent: subagent, now: context.date)
                                }
                            }
                        }
                    }
                    if !runs.isEmpty {
                        Section("Delegated Runs") {
                            ForEach(runs) { run in
                                DelegatedRunRow(run: run, now: context.date)
                            }
                        }
                    }
                    if !commands.isEmpty {
                        Section("Background Commands") {
                            ForEach(commands) { task in
                                BackgroundCommandRow(task: task, now: context.date)
                            }
                        }
                    }
                }
                .overlay {
                    if subagents.isEmpty, runs.isEmpty, commands.isEmpty {
                        ContentUnavailableView("Nothing in the Background", systemImage: "moon.zzz",
                                               description: Text("Subagents, delegated runs and commands the agent starts show up here."))
                    }
                }
            }
            .navigationTitle("Subagents & Tasks")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(for: Subagent.self) { subagent in
                SubagentThreadView(sessionId: sessionId, subagent: subagent)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { SheetCloseButton() }
            }
        }
        .task(id: session?.runtimeActivityRevision) {
            await store.refreshSubagentStatus(sessionId)
            await store.refreshBackgroundCommands(sessionId)
            await store.refreshDelegatedRuns(sessionId)
        }
    }
}


private struct SubagentRow: View {
    let subagent: Subagent
    let now: Date

    var body: some View {
        HStack(spacing: 10) {
            RobotIcon(size: 18)
                .foregroundStyle(subagent.status == .running ? Color.userBubble : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(subagent.title).lineLimit(2)
                HStack(spacing: 4) {
                    if let kind = subagent.kind { Text(kind) ; Text("·") }
                    Text(subagent.startedAt, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            StatusBadge(status: subagent.status, since: subagent.startedAt, until: subagent.status == .running ? now : subagent.lastActivityAt)
        }
        .padding(.vertical, 2)
    }
}

/// A run delegated through Happier: the agent it runs on, what it is, and how it went.
private struct DelegatedRunRow: View {
    let run: DelegatedRun
    let now: Date

    private var agentName: String {
        run.agentId.map { Agent.displayNames[$0] ?? $0 } ?? run.backendId ?? String(localized: "Agent")
    }

    /// "Delegate", "Review"… and, when it didn't succeed, how it ended.
    private var detail: String {
        let intent = run.intent.replacingOccurrences(of: "_", with: " ").capitalized
        let ending: String? = switch run.status {
        case "cancelled": String(localized: "Cancelled")
        case "timeout": String(localized: "Timed out")
        case "failed": run.errorMessage ?? String(localized: "Failed")
        default: nil
        }
        return [intent, ending].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            AgentAvatar(agentId: run.agentId, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.title ?? agentName).lineLimit(2)
                HStack(spacing: 4) {
                    if run.title != nil { Text(agentName); Text("·") }
                    Text(detail)
                    Text("·")
                    Text(run.startedAt, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            StatusBadge(status: run.isActive ? .running : run.status == "succeeded" ? .finished : .failed,
                        since: run.startedAt, until: run.isActive ? now : run.finishedAt)
        }
        .padding(.vertical, 2)
    }
}

private struct BackgroundCommandRow: View {
    let task: BackgroundCommand
    let now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "terminal")
                .foregroundStyle(task.isLive ? Color.userBubble : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.label ?? String(localized: "Background command"))
                    .font(.callout.monospaced())
                    .lineLimit(3)
                if let summary = task.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 8)
            StatusBadge(status: task.isLive ? .running : task.failed ? .failed : .finished,
                        since: task.startedAt, until: task.isLive ? now : task.endedAt)
        }
        .padding(.vertical, 2)
    }
}

/// Running with its elapsed time, done, or failed.
private struct StatusBadge: View {
    let status: Subagent.Status
    let since: Date?
    let until: Date?

    var body: some View {
        HStack(spacing: 4) {
            switch status {
            case .running:
                Circle().fill(Color.userBubble).frame(width: 7, height: 7)
            case .finished:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
            if let since, let until, until > since {
                Text(Duration.seconds(until.timeIntervalSince(since)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)))
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(status == .running ? "Running" : status == .failed ? "Failed" : "Done"))
    }
}

/// What a subagent did: its own conversation, from the prompt it got to its answer.
struct SubagentThreadView: View {
    let sessionId: String
    let subagent: Subagent
    @Environment(HappierStore.self) private var store
    @State private var thread: Transcript?
    @State private var error: String?

    var body: some View {
        Group {
            if let thread {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(thread.items) { item in
                            ChatItemView(item: item, sessionId: sessionId, tail: true)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .defaultScrollAnchor(.bottom)
                .overlay {
                    if thread.items.isEmpty {
                        ContentUnavailableView("No Messages Yet", systemImage: "ellipsis.bubble")
                    }
                }
            } else if let error {
                ContentUnavailableView("Can't Load", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                HappierSpinner(size: HappierSpinner.hero)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .modifier(SessionFilePreview(sessionId: sessionId))
        .navigationTitle(subagent.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            // Follows the subagent while it works.
            while !Task.isCancelled {
                do {
                    thread = try await store.subagentThread(sessionId, subagentId: subagent.id)
                } catch {
                    if thread == nil { self.error = error.localizedDescription }
                }
                let running = store.transcripts[sessionId]?.subagents.first { $0.id == subagent.id }?.status == .running
                guard running else { break }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

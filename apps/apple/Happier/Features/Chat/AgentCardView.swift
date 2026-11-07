import HappierKit
import SwiftUI

/// The agent card, opened by tapping the composer's status pill: who works in the session and how
/// it's doing, its engine, account and permission here, what its threads are doing now, its open
/// tasks, its recent memory, its description, and this session's controls. A session with no agent
/// shows its state, model, folder and machine, and its tasks. What is listed and in which order is
/// `AgentCard`'s; SF Symbols only, no emoji, color only for states.
struct AgentCardView: View {
    let sessionId: String
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Completed with the circle moments ago: still shown, struck through, and can be undone.
    @State private var completions = TaskCompletions()
    @State private var descriptionExpanded = false
    @State private var showTasks = false
    @State private var editing: AgentProfile?

    private enum Route: Hashable { case model, memory }

    private var session: Session? { store.sessions[sessionId] }
    private var identity: AgentIdentity? { session?.agentIdentity }
    private var profile: AgentProfile? { store.agentProfile(id: identity?.id) }
    private var controls: SessionControls? { store.controls(for: sessionId) }
    private var memory: AgentMemory? { identity.flatMap { store.agentMemories[$0.id] } }

    var body: some View {
        NavigationStack {
            if let session {
                content(session)
                    .navigationDestination(for: Route.self) { route in
                        switch route {
                        case .model:
                            SessionModelPicker(sessionId: sessionId)
                                .navigationTitle("Select Model")
                        case .memory:
                            if let profile { AgentMemoryView(agent: profile) }
                        }
                    }
            } else {
                ContentUnavailableView("Session Unavailable", systemImage: "bubble.left.and.exclamationmark.bubble.right")
            }
        }
        #if os(macOS)
        .frame(width: 380, height: 600)
        #else
        .frame(minWidth: 340, idealWidth: 380, minHeight: 480, idealHeight: 640)
        #endif
        .task(id: identity?.id) {
            async let tasks: Void = store.refreshTasks()
            if let agentId = identity?.id { await store.refreshAgentMemory(agentId: agentId) }
            await tasks
        }
        .sheet(isPresented: $showTasks) {
            Group {
                if let agentId = identity?.id {
                    TasksView(openSessionId: sessionId, assignee: .agent(agentId))
                } else {
                    TasksView(openSessionId: sessionId, onlyThisSession: true)
                }
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 560)
            #endif
        }
        .sheet(item: $editing) { profile in
            NavigationStack { AgentEditor(profile: profile, isNew: false) }
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 620)
            #endif
        }
    }

    private func content(_ session: Session) -> some View {
        let sections = AgentCard.sections(hasAgent: identity != nil, profileKnown: profile != nil,
                                          hasDescription: profile?.description?.isEmpty == false)
        return Form {
            if identity != nil { header(session) }
            ForEach(sections, id: \.self) { section in
                switch section {
                case .sessionState: sessionState(session)
                case .now: nowSection
                case .tasks: tasksSection
                case .memory: memorySection
                case .description: descriptionSection
                case .thisSession: thisSessionSection(session)
                case .editAgent: editSection
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(verbatim: identity?.name ?? session.title))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(role: .close) {
                    AppHaptics.light()
                    dismiss()
                }
            }
        }
        #endif
    }

    // MARK: Header

    /// The engine's logo, the name, the state as the pill shows it, then model, account and permission.
    private func header(_ session: Session) -> some View {
        Section {
            HStack(spacing: 12) {
                ProviderLogo(providerId: session.agentId ?? profile?.providerId ?? "claude", size: 26)
                    .frame(width: 52, height: 52)
                    .glassEffect(.regular, in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: identity?.name ?? "")
                        .font(.title2.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    SessionStatusRow(session: session)
                        .accessibilityElement(children: .combine)
                }
                Spacer(minLength: 0)
            }
            chips
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
    }

    @ViewBuilder private var chips: some View {
        let model = controls.map { modelChip($0) }
        let permission = controls.map { permissionChip($0) }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) {
                model
                accountChip
                permission
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    model
                    accountChip
                }
                permission
            }
        }
    }

    private func modelChip(_ controls: SessionControls) -> some View {
        HStack(spacing: 6) {
            Text(controls.displayModelName).lineLimit(1)
            if let effort = controls.displayEffort,
               let bars = EffortBars(level: effort, levels: controls.effortModel?.effortLevels ?? [], ultracode: controls.ultracode == true) {
                EffortBarsMark(bars: bars)
                    .accessibilityLabel(Text(controls.ultracode == true ? "Effort Ultracode" : "Effort \(EffortSlider.name(effort))"))
            }
        }
        .modifier(Chip())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Model \(controls.displayModelName)"))
    }

    @ViewBuilder private var accountChip: some View {
        if let profile {
            let label = profile.account.label.isEmpty ? (profile.claudeConfigDir ?? String(localized: "This machine's login")) : profile.account.label
            Label { Text(label).lineLimit(1) } icon: { Image(systemName: "person.crop.circle") }
                .labelStyle(.titleAndIcon)
                .modifier(Chip())
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Account: \(label)"))
        }
    }

    private func permissionChip(_ controls: SessionControls) -> some View {
        let mode = controls.permissionMode
        let label = mode.label(agentId: controls.agentId)
        return HStack(spacing: 4) {
            PermissionSymbol(mode: mode, textStyle: .footnote, side: 16)
            Text(label).lineLimit(1)
        }
        .foregroundStyle(.primary)
        .modifier(Chip())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Permission mode: \(label)"))
    }

    // MARK: No agent

    private func sessionState(_ session: Session) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                SessionStatusRow(session: session)
                Text(AgentCard.sessionLine(model: controls?.displayModelName, folder: session.folderName,
                                           machine: store.machines.first { $0.id == session.machineId }?.name ?? session.host))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } header: {
            Text("This Session")
        } footer: {
            // Who a session works as is chosen when it starts (New Session); there is no way yet to
            // give a running session an agent.
            Text("Start a session as one of your agents from New Session.")
        }
    }

    // MARK: Now

    private var nowSection: some View {
        let rows = AgentCard.nowRows(memory, sessionId: sessionId, now: ServerClock.nowMs(),
                                     status: { store.sessions[$0]?.status() }, title: { store.sessions[$0]?.title })
        return Section {
            if rows.isEmpty {
                Text(memory == nil ? "Loading…" : "No thread has reported yet.").foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                if row.isThisSession {
                    nowRow(row)
                } else {
                    Button {
                        AppHaptics.light()
                        dismiss()
                        Task { await store.openRelatedSession(row.sessionId) }
                    } label: {
                        HStack {
                            nowRow(row)
                            Image(systemName: "chevron.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityHint(Text("Opens that session"))
                }
            }
        } header: {
            Text("Now")
        }
    }

    private func nowRow(_ row: AgentCard.NowRow) -> some View {
        let text = row.text.isEmpty ? String(localized: "Working") : row.text
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            StateDot(state: row.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.isThisSession ? String(localized: "In this session: \(text)") : text)
                    .foregroundStyle(.primary)
                Text([row.place, row.ago.text].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(row.state.label). \(row.isThisSession ? String(localized: "In this session: \(text)") : text). \([row.place, row.ago.text].compactMap { $0 }.joined(separator: ", "))"))
    }

    // MARK: Tasks

    private var tasksSection: some View {
        let list = AgentCard.tasks(store.tasks, agentId: identity?.id, sessionId: sessionId, lingering: completions.lingeringIds)
        return Section {
            if list.tasks.isEmpty {
                Text("No open tasks.").foregroundStyle(.secondary)
            }
            ForEach(list.tasks) { task in
                taskRow(task)
            }
            Button(identity == nil ? "See This Session's Tasks" : "See All Its Tasks") {
                AppHaptics.light()
                showTasks = true
            }
        } header: {
            if identity == nil {
                Text("This Session's Tasks")
            } else {
                Text("Its Tasks · \(list.openCount) open")
            }
        }
        .animation(reduceMotion ? nil : .smooth, value: list.tasks.map(\.id))
    }

    private func taskRow(_ task: AgentTask) -> some View {
        let completedHere = completions.lingeringIds.contains(task.id)
        let done = task.status == .done || completedHere
        let here = task.isLinked(to: sessionId)
        let detail = [here ? String(localized: "This session") : nil, task.status.label, task.due()?.text].compactMap { $0 }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            if task.completesFromList || completedHere {
                Button {
                    toggleDone(task)
                } label: {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .font(.title3)
                .accessibilityLabel(done ? "Mark as not done" : "Complete")
            } else {
                Image(systemName: task.recurrence != nil ? "repeat.circle" : "circle")
                    .foregroundStyle(.tertiary)
                    .font(.title3)
                    .accessibilityLabel(task.recurrence != nil ? "Repeats; archive or pause it instead" : "Open")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .strikethrough(done)
                    .foregroundStyle(completedHere ? .secondary : .primary)
                    .lineLimit(2)
                Text(detail.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The Tasks list's circle (`TaskCompletions`): completes now, can be undone for a moment.
    private func toggleDone(_ task: AgentTask) {
        if completions.lingeringIds.contains(task.id) {
            guard let undo = completions.undo(task.id) else { return }
            AppHaptics.light()
            Task { await store.updateTask(id: task.id, undo) }
            return
        }
        guard let done = completions.complete(task, now: ServerClock.nowMs()) else { return }
        AppHaptics.success()
        Task { await store.updateTask(id: task.id, done) }
        Task {
            try? await Task.sleep(for: .milliseconds(Int(TaskCompletions.lingerMs) + 100))
            withAnimation(reduceMotion ? nil : .smooth) { completions.expire(now: ServerClock.nowMs()) }
        }
    }

    // MARK: Memory

    private var memorySection: some View {
        Section {
            let entries = AgentCard.recentMemory(memory)
            if entries.isEmpty {
                Text(memory == nil ? "Loading…" : "Nothing in its journal yet.").foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.text).lineLimit(3)
                    MemoryWhen(date: Date(timeIntervalSince1970: entry.at / 1000))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if profile != nil {
                NavigationLink(value: Route.memory) { Text("See Memory") }
            }
        } header: {
            Text("Recent Memory")
        }
    }

    // MARK: Description

    @ViewBuilder private var descriptionSection: some View {
        if let description = profile?.description {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(descriptionExpanded ? nil : 3)
                    Button(descriptionExpanded ? "Less" : "More") {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { descriptionExpanded.toggle() }
                    }
                    .buttonStyle(.borderless)
                    .font(.subheadline)
                    .accessibilityLabel(descriptionExpanded ? "Show less of the description" : "Show the whole description")
                }
            } header: {
                Text("Who It Is")
            }
        }
    }

    // MARK: Actions

    private func thisSessionSection(_ session: Session) -> some View {
        Section {
            if controls != nil {
                NavigationLink(value: Route.model) {
                    Label("Change Model or Effort", systemImage: "slider.horizontal.3")
                }
            }
            Button {
                AppHaptics.light()
                Task { await store.setNotificationsMuted(!session.notificationsMuted, in: sessionId) }
            } label: {
                Label(session.notificationsMuted ? "Turn On Notifications" : "Mute This Session",
                      systemImage: session.notificationsMuted ? "bell" : "bell.slash")
            }
        } header: {
            Text("This Session")
        }
    }

    private var editSection: some View {
        Section {
            Button {
                AppHaptics.light()
                editing = profile
            } label: {
                Label { Text("Edit \(profile?.name ?? "")") } icon: { Image(systemName: "pencil") }
            }
        } header: {
            Text("Agent")
        }
    }
}

/// A chip of the card's header: model, account, permission.
private struct Chip: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.fill.tertiary, in: Capsule())
    }
}

/// A row's state as a colored dot: green online, blue working, amber waiting on you, gray inactive.
private struct StateDot: View {
    let state: AgentCard.State

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch state {
        case .online: .green
        case .working: .userBubble
        case .waiting: .orange
        case .inactive: .gray
        }
    }
}

/// "Today 12:31", "Yesterday", else the date.
private struct MemoryWhen: View {
    let date: Date

    var body: some View {
        if Calendar.current.isDateInToday(date) {
            Text("Today \(date, format: .dateTime.hour().minute())")
        } else if Calendar.current.isDateInYesterday(date) {
            Text("Yesterday")
        } else {
            Text(date, format: .dateTime.month().day())
        }
    }
}

extension AgentCard.State {
    var label: String {
        switch self {
        case .online: String(localized: "Online")
        case .working: String(localized: "Working")
        case .waiting: String(localized: "Waiting for you")
        case .inactive: String(localized: "Inactive")
        }
    }
}

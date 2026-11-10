import HappierKit
import SwiftUI

/// An agent's whole profile, opened from the sidebar's Agents like a session (in the detail on Mac
/// and iPad, full screen on the iPhone): who it is, its engine, account and weekly usage, its
/// backlog by status with "Start Now" on each task, its open sessions with what each one says it's
/// doing, its recent memory and Edit. It sits straight in the detail column, as a conversation does
/// (its title and Edit are the column's); a task opens where tasks open (`HappierStore.tasksRequest`:
/// the Tasks panel on iPad and Mac, the Tasks sheet on the iPhone) and the memory in a sheet.
struct AgentProfileView: View {
    let agentId: String
    @Environment(HappierStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var newSession = false
    @State private var newTask = false
    @State private var editing: AgentProfile?
    @State private var showMemory = false
    @State private var descriptionExpanded = false
    @State private var showDone = false
    /// "Start Now" pressed on a task: `taskStart` starts it.
    @State private var startRequest: String?
    @State private var starting = false
    /// A task from the Tasks panel is being dragged over the profile: its empty space, or how many
    /// of its rows (moving from one row to the next is briefly over both).
    @State private var dropTargeted = false
    @State private var rowsTargeted = 0

    private var profile: AgentProfile? { store.agentProfile(id: agentId) }
    private var memory: AgentMemory? { store.agentMemories[agentId] }

    var body: some View {
        Group {
            if let profile {
                content(profile)
            } else if store.agentProfiles.isEmpty {
                HappierSpinner(size: HappierSpinner.hero)
            } else {
                ContentUnavailableView("Agent Not Found", systemImage: "person.crop.circle.badge.questionmark",
                                       description: Text("It may have been deleted on another device."))
            }
        }
        .task(id: agentId) {
            async let tasks: Void = store.refreshTasks()
            await store.refreshAgentMemory(agentId: agentId)
            await tasks
        }
        .taskStart($startRequest, working: $starting) { sessionId in
            await store.openRelatedSession(sessionId)
        }
        .sheet(isPresented: $newSession) {
            NewSessionSheet(preselectedAgentId: agentId)
        }
        .sheet(isPresented: $newTask) {
            if let profile { NewTaskSheet(assignee: .agent(profile)) }
        }
        .sheet(isPresented: $showMemory) {
            if let profile {
                NavigationStack {
                    AgentMemoryView(agent: profile)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { SheetCloseButton() } }
                }
                #if os(macOS)
                .frame(minWidth: 460, minHeight: 560)
                #endif
            }
        }
        .sheet(item: $editing) { profile in
            NavigationStack { AgentEditor(profile: profile, isNew: false) }
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 620)
            #endif
        }
    }

    private func content(_ profile: AgentProfile) -> some View {
        // "Working" fades after two minutes without news, as in the sidebar's rows.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let filterContext = SessionListFilter.Context(tasks: store.tasks)
            let now = store.presenceDate(context.date)
            let summary = AgentRoster.summary(of: profile, sessions: store.sessionList, context: filterContext, now: now,
                                              usage: { store.usage(for: $0.id) })
            Form {
                header(profile, summary: summary)
                tasksSections(profile)
                sessionsSection(summary, context: filterContext, now: now)
                memorySection
                if let description = profile.description, !description.isEmpty { descriptionSection(description) }
            }
            .formStyle(.grouped)
        }
        // A task dropped anywhere on the profile is assigned to the agent (nothing starts). On iOS
        // the list's rows take drops, not the list around them: each row is a target too (`droppable`).
        .overlay {
            if dropTargeted || rowsTargeted > 0 { dropHighlight(profile) }
        }
        .taskDrop(onto: profile, targeted: $dropTargeted)
        .navigationTitle(Text(verbatim: profile.name))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") {
                    AppHaptics.light()
                    editing = profile
                }
                .accessibilityIdentifier("agent-profile-edit")
            }
        }
    }

    /// One of the profile's rows as a place to drop a task (lighting the whole profile).
    private func droppable(_ row: some View) -> some View {
        row.modifier(ProfileRowDrop(agentId: agentId, targetedRows: $rowsTargeted))
    }

    /// The profile lit as the drop target, saying what dropping does.
    private func dropHighlight(_ profile: AgentProfile) -> some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.userBubble, lineWidth: 3)
            .background(Color.userBubble.opacity(0.06), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(alignment: .top) {
                Label("Assign to \(profile.name)", systemImage: "person.crop.circle.badge.plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.top, 12)
            }
            .padding(8)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    // MARK: Header

    /// The emoji on its engine's disc, the name, engine and account, the account's weekly usage,
    /// and a new session with it.
    private func header(_ profile: AgentProfile, summary: AgentSummary) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    AgentAvatar(agentId: profile.providerId, size: 64, emoji: profile.emoji)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(verbatim: profile.name)
                                .font(.title.weight(.bold))
                                .lineLimit(1)
                                .accessibilityAddTraits(.isHeader)
                            ProviderLogo(providerId: profile.providerId, size: 18)
                        }
                        Text(AgentProfileText.engine(profile, sessions: store.sessionList))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(AgentProfileText.account(profile))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                usage(summary.weekly)
                Button {
                    AppHaptics.light()
                    newSession = true
                } label: {
                    Label("New Session with \(profile.name)", systemImage: "plus")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .accessibilityIdentifier("agent-new-session")
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .modifier(ProfileRowDrop(agentId: agentId, targetedRows: $rowsTargeted))
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 8, trailing: 4))
    }

    private func usage(_ weekly: ProviderUsage.Meter?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Weekly Usage").font(.subheadline.weight(.medium))
                Spacer()
                if let weekly {
                    Text("\(Int(weekly.usedPercent.rounded()))% used")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
            }
            ProgressView(value: (weekly?.usedPercent ?? 0) / 100).tint(weekly?.isNearLimit == true ? .red : .primary)
            Group {
                if let reset = weekly?.resetsAt {
                    Text("Resets \(reset.formatted(.dateTime.weekday(.wide))) at \(reset.formatted(date: .omitted, time: .shortened))")
                } else if weekly == nil {
                    Text("Weekly usage is not available yet.")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Tasks

    /// Its backlog by status (`AgentCard.backlog`), Done folded away; assigning never starts a task,
    /// "Start Now" on a row does.
    @ViewBuilder
    private func tasksSections(_ profile: AgentProfile) -> some View {
        let backlog = AgentCard.backlog(store.tasks, agentId: agentId)
        let open = backlog.filter { $0.status != .done }
        Section {
            if backlog.isEmpty {
                droppable(Text("No tasks for \(profile.name) yet.").foregroundStyle(.secondary))
            }
            droppable(Button("New Task for \(profile.name)", systemImage: "plus") {
                AppHaptics.light()
                newTask = true
            })
        } header: {
            Text("Tasks · \(open.reduce(0) { $0 + $1.tasks.count }) open")
        }
        ForEach(open) { group in
            Section {
                ForEach(group.tasks) { droppable(taskRow($0)) }
            } header: {
                Text("\(group.status.label) · \(group.tasks.count)")
            }
        }
        if let done = backlog.first(where: { $0.status == .done }) {
            Section {
                DisclosureGroup(isExpanded: $showDone.animation(reduceMotion ? nil : .smooth(duration: 0.25))) {
                    ForEach(done.tasks) { droppable(taskRow($0)) }
                } label: {
                    Text("\(AgentTask.Status.done.label) · \(done.tasks.count)")
                }
            }
        }
    }

    private func taskRow(_ task: AgentTask) -> some View {
        let actions = task.availableActions(from: .list)
        return HStack(alignment: .center, spacing: 8) {
            Button {
                AppHaptics.selection()
                store.tasksRequest = .task(task.id)
            } label: {
                HStack(spacing: 8) {
                    TaskRow(task: task, openSession: { sessionId in Task { await store.openRelatedSession(sessionId) } })
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier("agent-task-\(task.id)")
            if actions.offersStartNow {
                Button {
                    AppHaptics.light()
                    startRequest = task.id
                } label: {
                    Label("Start Now", systemImage: "play.fill")
                        .labelStyle(.iconOnly)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .disabled(starting)
                .help(Text("Start Now"))
                .accessibilityIdentifier("agent-task-start-\(task.id)")
            }
        }
        .contextMenu {
            if actions.offersStartNow {
                Button("Start Now", systemImage: "play.fill") { startRequest = task.id }
            }
            Button("Open", systemImage: "arrow.up.forward.square") { store.tasksRequest = .task(task.id) }
        }
    }

    // MARK: Sessions and now

    /// Its open sessions, each with what its thread last said it is doing (the memory's `now`).
    @ViewBuilder
    private func sessionsSection(_ summary: AgentSummary, context: SessionListFilter.Context, now: Date) -> some View {
        Section {
            if summary.sessions.isEmpty {
                droppable(Text("No open sessions").foregroundStyle(.secondary))
            }
            ForEach(summary.sessions) { session in
                droppable(Button {
                    AppHaptics.selection()
                    Task { await store.openRelatedSession(session.id) }
                } label: {
                    sessionRow(session, state: AgentRoster.state(of: session, context: context, now: now))
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("agent-session-\(session.id)"))
            }
        } header: {
            Text("Open Sessions · \(summary.open)")
        }
    }

    private func sessionRow(_ session: Session, state: AgentSummary.SessionState) -> some View {
        let doing = memory?.now.first { $0.sessionId == session.id }?.text
        return HStack(spacing: 10) {
            Group {
                switch state {
                case .working: HappierSpinner(size: HappierSpinner.mini, color: .userBubble)
                case .needsYou: Circle().fill(Color.orange).frame(width: 8, height: 8)
                case .idle: Circle().fill(Color.secondary.opacity(0.6)).frame(width: 8, height: 8)
                }
            }
            .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(doing.flatMap { $0.isEmpty ? nil : $0 } ?? session.listDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(doing == nil ? .head : .tail)
            }
            Spacer(minLength: 8)
            Group {
                switch state {
                case .working: Text("Working").foregroundStyle(Color.userBubble)
                case .needsYou: Text("Needs you").foregroundStyle(Color.orange)
                case .idle: Text(session.sortDate, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .lineLimit(1)
            .fixedSize()
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    // MARK: Memory and description

    private var memorySection: some View {
        Section {
            let entries = AgentCard.recentMemory(memory)
            if entries.isEmpty {
                droppable(Text(memory == nil ? "Loading…" : "Nothing in its journal yet.").foregroundStyle(.secondary))
            }
            ForEach(entries) { entry in
                droppable(VStack(alignment: .leading, spacing: 2) {
                    Text(entry.text).lineLimit(3)
                    Text(Date(timeIntervalSince1970: entry.at / 1000), format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine))
            }
            Button {
                showMemory = true
            } label: {
                HStack {
                    Text("See Memory")
                    Spacer()
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
        } header: {
            Text("Recent Memory")
        }
    }

    private func descriptionSection(_ description: String) -> some View {
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
            }
        } header: {
            Text("Who It Is")
        }
    }
}

/// A row of the profile that takes a dropped task for the agent, counting itself in `targetedRows`
/// while one is over it.
private struct ProfileRowDrop: ViewModifier {
    let agentId: String
    @Binding var targetedRows: Int
    @State private var over = false
    @Environment(HappierStore.self) private var store

    func body(content: Content) -> some View {
        if let agent = store.agentProfile(id: agentId) {
            content
                .taskDrop(onto: agent, targeted: $over)
                .onChange(of: over) { _, now in targetedRows = max(0, targetedRows + (now ? 1 : -1)) }
        } else {
            content
        }
    }
}

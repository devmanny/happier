import HappierKit
import SwiftUI

/// An agent's card, like a contact's, opened from its chat's header (`AgentChatView`): beside the chat
/// on iPad and Mac, a sheet on the iPhone, with its own Close and Edit on top (nothing goes into the
/// chat's bar). Its photo, name, engine and account; three round buttons: a new session with it, its
/// tasks (the one Tasks list, filtered to it) and its memory, each in a sheet; then two tabs. Sessions:
/// its open sessions, each with what its thread says it's doing, and its account's weekly usage.
/// Can Do: what the user says it can do (`AgentProfile.canDo`) and who it is. A task dropped anywhere
/// on the card is assigned to it; nothing starts.
struct AgentProfileView: View {
    let agentId: String
    /// Puts the card away: the panel beside the chat, or the iPhone's sheet.
    let close: () -> Void
    @Environment(HappierStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The round buttons grow with the text size.
    @ScaledMetric(relativeTo: .title3) private var roundButtonSize: CGFloat = 36
    @State private var tab = Tab.sessions
    @State private var newSession = false
    @State private var showTasks = false
    @State private var showMemory = false
    @State private var editing: AgentProfile?
    @State private var descriptionExpanded = false
    /// A task from the Tasks panel is being dragged over the card: its empty space, or how many
    /// of its rows (moving from one row to the next is briefly over both).
    @State private var dropTargeted = false
    @State private var rowsTargeted = 0

    private enum Tab: String, CaseIterable {
        case sessions, canDo

        var title: LocalizedStringKey {
            switch self {
            case .sessions: "Sessions"
            case .canDo: "Can Do"
            }
        }
    }

    private var profile: AgentProfile? { store.agentProfile(id: agentId) }
    private var memory: AgentMemory? { store.agentMemories[agentId] }

    var body: some View {
        Group {
            if let profile {
                content(profile)
            } else if store.agentProfiles.isEmpty {
                HappierSpinner(size: HappierSpinner.hero)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Agent Not Found", systemImage: "person.crop.circle.badge.questionmark",
                                       description: Text("It may have been deleted on another device."))
            }
        }
        .safeAreaBar(edge: .top) { topBar }
        // Its tasks decide which sessions need you; its memory says what each one is doing.
        .task(id: agentId) {
            async let tasks: Void = store.refreshTasks()
            await store.refreshAgentMemory(agentId: agentId)
            await tasks
        }
        .sheet(isPresented: $newSession) {
            NewSessionSheet(preselectedAgentId: agentId)
        }
        .sheet(isPresented: $showTasks) {
            TasksView(assignee: .agent(agentId))
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 560)
                #endif
        }
        .sheet(isPresented: $showMemory) {
            if let profile {
                NavigationStack {
                    AgentMemoryView(agent: profile)
                        .sheetCloseButton()
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

    /// Close on the left, Edit on the right, over the card as it scrolls.
    private var topBar: some View {
        HStack {
            Button {
                AppHaptics.light()
                close()
            } label: {
                Label("Close", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .fontWeight(.semibold)
            }
            .buttonBorderShape(.circle)
            .help(Text("Close"))
            .accessibilityIdentifier("agent-profile-close")
            Spacer()
            if let profile {
                Button("Edit") {
                    AppHaptics.light()
                    editing = profile
                }
                .accessibilityIdentifier("agent-profile-edit")
            }
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func content(_ profile: AgentProfile) -> some View {
        // "Working" fades after two minutes without news, as in the sidebar's rows.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let filterContext = SessionListFilter.Context(tasks: store.tasks)
            let now = store.presenceDate(context.date)
            let summary = AgentRoster.summary(of: profile, sessions: store.sessionList, context: filterContext, now: now,
                                              usage: { store.usage(for: $0.id) })
            Form {
                header(profile)
                switch tab {
                case .sessions:
                    sessionsSection(summary, context: filterContext, now: now)
                    usageSection(summary.weekly)
                case .canDo:
                    canDoSections(profile)
                }
            }
            .formStyle(.grouped)
        }
        // A task dropped anywhere on the card is assigned to the agent (nothing starts). On iOS the
        // list's rows take drops, not the list around them: each row is a target too (`droppable`).
        .overlay {
            if dropTargeted || rowsTargeted > 0 { dropHighlight(profile) }
        }
        .taskDrop(onto: profile, targeted: $dropTargeted)
    }

    /// One of the card's rows as a place to drop a task (lighting the whole card).
    private func droppable(_ row: some View) -> some View {
        row.modifier(ProfileRowDrop(agentId: agentId, targetedRows: $rowsTargeted))
    }

    /// The card lit as the drop target, saying what dropping does.
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

    /// Its photo, name, engine and account, the round buttons and the tabs, centered.
    private func header(_ profile: AgentProfile) -> some View {
        Section {
            VStack(spacing: 3) {
                AgentProfileAvatar(profile: profile, size: 100)
                Text(verbatim: profile.name)
                    .font(.title.weight(.bold))
                    .lineLimit(2)
                    .padding(.top, 6)
                    .accessibilityAddTraits(.isHeader)
                Text(AgentProfileText.engine(profile, sessions: store.sessionList))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(AgentProfileText.account(profile))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                actions(profile)
                    .padding(.top, 14)
                tabs
                    .padding(.top, 12)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .modifier(ProfileRowDrop(agentId: agentId, targetedRows: $rowsTargeted))
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
    }

    /// New session, its tasks, its memory.
    private func actions(_ profile: AgentProfile) -> some View {
        HStack(spacing: 16) {
            roundButton("New Session", systemImage: "square.and.pencil", hint: "Starts a session with \(profile.name)",
                        id: "agent-new-session") { newSession = true }
            roundButton("Tasks", systemImage: "checklist", hint: "Shows \(profile.name)'s tasks",
                        id: "agent-profile-tasks") { showTasks = true }
            roundButton("Memory", systemImage: "brain", hint: "Shows \(profile.name)'s memory",
                        id: "agent-profile-memory") { showMemory = true }
        }
    }

    private func roundButton(_ title: LocalizedStringKey, systemImage: String, hint: LocalizedStringKey, id: String,
                             action: @escaping () -> Void) -> some View {
        Button {
            AppHaptics.light()
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: roundButtonSize, height: roundButtonSize)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help(Text(title))
        .accessibilityHint(Text(hint))
        .accessibilityIdentifier(id)
    }

    /// Pills, the chosen one filled.
    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases, id: \.self) { item in
                let selected = tab == item
                Button {
                    AppHaptics.selection()
                    tab = item
                } label: {
                    Text(item.title)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)
                        .padding(.horizontal, 13)
                        .frame(minHeight: 34)
                        .background(selected ? Color.primary.opacity(0.12) : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("agent-profile-tab-\(item.rawValue)")
            }
        }
    }

    // MARK: Sessions

    /// Its open sessions, each with what its thread last said it is doing (the memory's `now`), else
    /// its folder, by the one rule a session card in a chat follows too (`AgentRoster.line`).
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
                    sessionRow(AgentRoster.line(of: session, memory: memory, context: context, now: now))
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("agent-session-\(session.id)"))
            }
        } header: {
            Text("Open Sessions · \(summary.open)")
        }
    }

    private func sessionRow(_ line: AgentRoster.SessionLine) -> some View {
        HStack(spacing: 10) {
            Group {
                switch line.state {
                case .working: HappierSpinner(size: HappierSpinner.mini, color: .userBubble)
                case .needsYou: Circle().fill(Color.orange).frame(width: 8, height: 8)
                case .idle: Circle().fill(Color.secondary.opacity(0.6)).frame(width: 8, height: 8)
                }
            }
            .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: line.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(verbatim: line.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(line.doing ? .tail : .head)
            }
            Spacer(minLength: 8)
            Group {
                switch line.state {
                case .working: Text("Working").foregroundStyle(Color.userBubble)
                case .needsYou: Text("Needs you").foregroundStyle(Color.orange)
                case .idle: Text(line.lastActivity, format: .relative(presentation: .named)).foregroundStyle(.secondary)
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

    /// The weekly usage of the account it runs on, below its sessions.
    private func usageSection(_ weekly: ProviderUsage.Meter?) -> some View {
        Section {
            droppable(VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Weekly Usage")
                    Spacer()
                    if let weekly {
                        Text("\(Int(weekly.usedPercent.rounded()))% used")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                ProgressView(value: (weekly?.usedPercent ?? 0) / 100).tint(weekly?.isNearLimit == true ? .red : Color.userBubble)
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
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine))
        }
    }

    // MARK: Can Do

    /// What it can do, as chips, then who it is; with neither, a way to add them.
    @ViewBuilder
    private func canDoSections(_ profile: AgentProfile) -> some View {
        let description = profile.description.flatMap { $0.isEmpty ? nil : $0 }
        if profile.canDo.isEmpty, description == nil {
            Section {
                droppable(VStack(spacing: 10) {
                    Text("Add what \(profile.name) can do and who it is.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Edit") {
                        AppHaptics.light()
                        editing = profile
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("agent-profile-can-do-edit")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8))
            }
        } else {
            if !profile.canDo.isEmpty {
                Section {
                    droppable(ChipsLayout(spacing: 8) {
                        ForEach(Array(profile.canDo.enumerated()), id: \.offset) { _, item in
                            Text(item)
                                .font(.subheadline)
                                .lineLimit(2)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                        }
                    }
                    .padding(.vertical, 4))
                }
            }
            if let description { descriptionSection(description) }
        }
    }

    private func descriptionSection(_ description: String) -> some View {
        Section {
            droppable(VStack(alignment: .leading, spacing: 6) {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(descriptionExpanded ? nil : 3)
                Button(descriptionExpanded ? "Less" : "More") {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { descriptionExpanded.toggle() }
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
            })
        } header: {
            Text("About")
        }
    }
}

/// The Can Do chips in rows, wrapping to the next row when one doesn't fit; a chip wider than the
/// row gets the row's width (its text wraps, then truncates).
private struct ChipsLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width {
                size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
                size.width = min(size.width, width)
            }
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (frames, CGSize(width: widest, height: frames.isEmpty ? 0 : y + rowHeight))
    }
}

/// A row of the card that takes a dropped task for the agent, counting itself in `targetedRows`
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

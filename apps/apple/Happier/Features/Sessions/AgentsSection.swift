import HappierKit
import SwiftUI

/// "Agents" atop the session list: one circle per agent in a row that scrolls sideways, like
/// stories. The ring around each one is the weekly usage of its account, the count on it the
/// sessions that need you, and under its name what it is doing or when it last did something.
/// Tapping one opens its whole profile the way a session opens (selected in the sidebar, the
/// profile in the detail; full screen on the iPhone). The order is the account's
/// (`AccountSettings.agentOrder`): Edit lays them out as rows with drag handles to reorder them.
/// The section folds under its title. The list shows it once there are agents.
struct AgentsSection: View {
    /// The list's sessions (throttled by the list), every state but archived.
    let sessions: [Session]
    /// Shown in the iPhone drawer (rather than the sidebar): the rows take the drawer's session-row look.
    let drawer: Bool
    /// What the list has selected: a session, or an agent's profile (`AgentProfile.selection(id:)`).
    let selection: String?
    /// Opens a session or a profile the way the list does (the drawer's `onOpen`, or the split view's selection).
    let open: (String) -> Void
    /// "New Session with…": the list presents the new-session sheet for this agent.
    let newSession: (AgentProfile) -> Void
    /// Edit shows the agents as rows with drag handles. The list holds it: the edit mode only
    /// reaches the rows set on the whole list.
    @Binding var editing: Bool
    @Environment(HappierStore.self) private var store

    private var savedOrder: [String] { store.accountSettings?.agentOrder ?? [] }
    private var profiles: [AgentProfile] { AgentRoster.ordered(store.agentProfiles, by: savedOrder) }

    var body: some View {
        let profiles = profiles
        CollapsibleListSection("Agents", key: "agents", count: profiles.count, drawer: drawer, waiting: waiting(profiles)) {
            if editing {
                // Rows, to drag into place.
                ForEach(profiles) { profile in
                    AgentRow(profile: profile, sessions: sessions, drawer: drawer,
                             selected: selection == AgentProfile.selection(id: profile.id), open: open, newSession: newSession)
                }
                .onMove { offsets, destination in
                    let next = AgentRoster.order(afterMoving: offsets, to: destination, in: profiles.map(\.id), saved: savedOrder)
                    AppHaptics.selection()
                    Task { await store.updateAccountSettings { $0.delta(agentOrder: next) } }
                }
            } else {
                AgentStrip(profiles: profiles, sessions: sessions, selection: selection, open: open, newSession: newSession)
            }
        } accessory: {
            Button(editing ? "Done" : "Edit") {
                AppHaptics.light()
                withAnimation(.smooth(duration: 0.2)) { editing.toggle() }
            }
            .font(.subheadline.weight(editing ? .semibold : .regular))
            .buttonStyle(.borderless)
            .textCase(nil)
            .disabled(store.accountSettings == nil)
            .accessibilityIdentifier("agents-edit")
        }
        // Readings for agents with none shown yet: one read of one session each, when the section
        // appears or an agent gets a session to read from.
        .task(id: usageSources(profiles).map(\.id)) { await readMissingUsage(profiles) }
    }

    /// The sessions that need you across every agent: what the folded section still shows.
    private func waiting(_ profiles: [AgentProfile]) -> Int {
        let context = SessionListFilter.Context(tasks: store.tasks), now = store.presenceDate()
        return profiles.reduce(0) { total, profile in
            total + AgentRoster.openSessions(of: profile, in: sessions).count { context.needsAttention($0, now: now) }
        }
    }

    /// The session each agent's usage would be read from.
    private func usageSources(_ profiles: [AgentProfile]) -> [Session] {
        profiles.compactMap { AgentRoster.sessionToReadUsage(of: $0, sessions: sessions) }
    }

    private func readMissingUsage(_ profiles: [AgentProfile]) async {
        for profile in profiles {
            guard AgentRoster.weeklyUsage(of: profile, sessions: sessions, usage: { store.usage(for: $0.id) }) == nil,
                  let session = AgentRoster.sessionToReadUsage(of: profile, sessions: sessions) else { continue }
            await store.refreshProviderUsage(session.id)
        }
    }
}

/// The agents as circles in one row that scrolls sideways, like stories.
private struct AgentStrip: View {
    let profiles: [AgentProfile]
    let sessions: [Session]
    let selection: String?
    let open: (String) -> Void
    let newSession: (AgentProfile) -> Void
    @Environment(HappierStore.self) private var store
    @Environment(\.sessionListOnScreen) private var onScreen

    var body: some View {
        // "Working" fades after two minutes without news, as in the session rows.
        TimelineView(.periodic(from: .now, by: onScreen ? 30 : 3_600)) { context in
            let now = store.presenceDate(context.date)
            let filter = SessionListFilter.Context(tasks: store.tasks)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(profiles) { profile in
                        AgentBubble(profile: profile,
                                    summary: AgentRoster.summary(of: profile, sessions: sessions, context: filter, now: now,
                                                                 usage: { store.usage(for: $0.id) }),
                                    now: now, selected: selection == AgentProfile.selection(id: profile.id),
                                    open: open, newSession: newSession)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
        }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }
}

/// One agent's circle: its avatar inside the ring of its account's weekly usage, a count of the
/// sessions that need you (only when some do), its name, and under it "Working" or how long ago
/// it last did something. Quiet for a day, it fades.
private struct AgentBubble: View {
    let profile: AgentProfile
    let summary: AgentSummary
    let now: Date
    let selected: Bool
    let open: (String) -> Void
    let newSession: (AgentProfile) -> Void
    /// A task from the Tasks panel is being dragged over it.
    @State private var dropTargeted = false

    private static let size: CGFloat = 70
    /// The sessions-need-you count: the app's alert orange-red.
    private static let waiting = Color(red: 0xC2 / 255, green: 0x41 / 255, blue: 0x0C / 255)

    private var quiet: Bool {
        guard summary.latestWorking == nil else { return false }
        guard let last = summary.lastActivity else { return true }
        return now.timeIntervalSince(last) > 24 * 3600
    }

    var body: some View {
        Button {
            AppHaptics.selection()
            open(AgentProfile.selection(id: profile.id))
        } label: {
            VStack(spacing: 2) {
                ZStack {
                    // The disc is 82 % of the avatar; the ring sits just outside it.
                    AgentAvatar(agentId: profile.providerId, size: Self.size, emoji: profile.emoji)
                    AgentUsageRing(meter: summary.weekly, diameter: Self.size - 4, lineWidth: 3.5, tint: .userBubble)
                }
                .frame(width: Self.size, height: Self.size)
                .overlay(alignment: .topTrailing) {
                    if summary.needsYou > 0 {
                        Text(summary.needsYou, format: .number)
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .frame(minWidth: 22, minHeight: 22)
                            .background(Self.waiting, in: Capsule())
                            .offset(x: 2, y: -1)
                    }
                }
                .padding(.bottom, 2)
                Text(profile.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selected ? Color.userBubble : Color.primary)
                    .lineLimit(1)
                activity
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(width: Self.size + 8)
            .opacity(quiet && !selected ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A task dropped on it is assigned to the agent (nothing starts).
        .overlay {
            if dropTargeted { RowDropHighlight() }
        }
        .taskDrop(onto: profile, targeted: $dropTargeted)
        .contextMenu {
            Button("New Session with \(profile.name)", systemImage: "plus") { newSession(profile) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(summary.needsYou > 0 ? Text("\(summary.needsYou) need you") : Text(verbatim: ""))
        .accessibilityIdentifier("agent-row-\(profile.id)")
    }

    @ViewBuilder
    private var activity: some View {
        if summary.latestWorking != nil {
            Text("Working").fontWeight(.semibold).foregroundStyle(Color.userBubble)
        } else if let last = summary.lastActivity {
            Text(last, format: .relative(presentation: .numeric, unitsStyle: .narrow)).foregroundStyle(.secondary)
        } else {
            Text("No sessions").foregroundStyle(.secondary)
        }
    }
}

/// One agent: the emoji and name over "4 open · 1 working", then its provider logo, its account's
/// weekly usage ring and, only when something needs you, an amber count.
private struct AgentRow: View {
    let profile: AgentProfile
    let sessions: [Session]
    let drawer: Bool
    let selected: Bool
    let open: (String) -> Void
    let newSession: (AgentProfile) -> Void
    @Environment(HappierStore.self) private var store
    @Environment(\.sessionListOnScreen) private var onScreen
    #if os(iOS)
    @Environment(\.editMode) private var editMode
    private var isEditing: Bool { editMode?.wrappedValue.isEditing == true }
    #else
    private let isEditing = false
    #endif
    private var selection: String { AgentProfile.selection(id: profile.id) }
    /// A task from the Tasks panel is being dragged over it.
    @State private var dropTargeted = false

    var body: some View {
        Group {
            if drawer {
                // The drawer's rows are buttons, as its session rows are; the selected one keeps
                // their rounded highlight.
                Button {
                    AppHaptics.selection()
                    open(selection)
                } label: {
                    content
                }
                .buttonStyle(.plain)
                .sessionListRow(drawer: drawer)
                .listRowBackground(selected ? DrawerRowHighlight().fill(Color.primary.opacity(0.1)) : nil)
            } else {
                // The sidebar selects it like a session row: the list's own selection highlight.
                content
                    .sessionListRow(drawer: drawer)
                    .tag(selection)
            }
        }
        // A task dropped on the row is assigned to the agent (nothing starts), lit like a session
        // row taking a session.
        .overlay {
            if dropTargeted { RowDropHighlight() }
        }
        .taskDrop(onto: profile, targeted: $dropTargeted)
        .sessionListRowLift(drawer: drawer)
        .accessibilityIdentifier("agent-row-\(profile.id)")
        .contextMenu {
            Button("New Session with \(profile.name)", systemImage: "plus") { newSession(profile) }
        }
    }

    private var content: some View {
        // "Working" fades after two minutes without news, as in the session rows.
        TimelineView(.periodic(from: .now, by: onScreen ? 30 : 3_600)) { context in
            label(AgentRoster.summary(of: profile, sessions: sessions, context: SessionListFilter.Context(tasks: store.tasks),
                                      now: store.presenceDate(context.date), usage: { store.usage(for: $0.id) }))
        }
        .contentShape(Rectangle())
    }

    private func label(_ summary: AgentSummary) -> some View {
        HStack(spacing: 8) {
            // The session rows' avatar: the emoji on the provider's glass disc, at their size.
            AgentAvatar(agentId: profile.providerId, size: SessionListView.drawerAvatar, emoji: profile.emoji)
                .padding(.trailing, SessionListView.avatarGap - 8)
            VStack(alignment: .leading, spacing: 1) {
                // The provider's logo right after the name, on its line.
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    ProviderLogo(providerId: profile.providerId, size: 14)
                }
                AgentActivityLine(summary: summary)
                    .font(.caption)
                    .lineLimit(1)
            }
            // The text takes the room the indicators leave and never reaches them: a 14 pt gap.
            .padding(.trailing, 14 - 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            // While reordering, the drag handles take the indicators' place.
            if !isEditing {
                if summary.open > 0 {
                    OpenSessionsBadge(count: summary.open, needsYou: summary.needsYou > 0)
                }
                AgentUsageRing(meter: summary.weekly)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "4 open · 1 working", the working count in the list's working blue; "No open sessions" at none.
/// The row's second line (provisional): what its newest working session is, else when it last
/// did something, else that nothing is open.
private struct AgentActivityLine: View {
    let summary: AgentSummary

    var body: some View {
        if let working = summary.latestWorking {
            let others = summary.working - 1
            // Only the session's title gives way (…); "Working on" and "+N" always show whole.
            HStack(spacing: 0) {
                Text("\(Text("Working").foregroundStyle(Color.userBubble)) \(Text("on").foregroundStyle(.secondary)) ")
                    .fixedSize()
                    .layoutPriority(2)
                Text(working.title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if others > 0 {
                    Text(" +\(others)")
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .layoutPriority(2)
                }
            }
        } else if let last = summary.lastActivity {
            Text("Last activity \(last, format: .relative(presentation: .named, unitsStyle: .abbreviated))").foregroundStyle(.secondary)
        } else {
            Text("No open sessions").foregroundStyle(.secondary)
        }
    }
}

/// The model picker's agent icon, as in Settings: its emoji centered on a gray rounded square.
struct AgentIcon: View {
    let emoji: String?

    private var tile: Color {
        #if os(iOS)
        Color(uiColor: .systemGray2)
        #else
        Color(nsColor: .systemGray)
        #endif
    }

    var body: some View {
        AgentEmoji(emoji: emoji, size: 24)
            .frame(width: 30, height: 30)
            .background(tile, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// The agent's emoji, or a neutral person where it has none.
private struct AgentEmoji: View {
    let emoji: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let emoji, !emoji.isEmpty {
                Text(emoji).font(.system(size: size * 0.75))
            } else {
                Image(systemName: "person.crop.circle").font(.system(size: size * 0.8)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The account's weekly usage on a gray track: primary (or the tint), red from 80 % used (`isNearLimit`, the
/// rule every usage ring and bar draws); an empty track without a reading.
private struct AgentUsageRing: View {
    let meter: ProviderUsage.Meter?
    var diameter: CGFloat = 20
    var lineWidth: CGFloat = 2.6
    /// The used part's color while it isn't near the limit.
    var tint: Color = .primary

    private var fraction: Double? { meter.map { $0.usedPercent / 100 } }

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: lineWidth)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.02, min(fraction, 1)))
                    .stroke(meter?.isNearLimit == true ? Color.red : tint,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement()
        .accessibilityLabel(Text("Weekly usage"))
        .accessibilityValue(fraction.map { Text($0, format: .percent.precision(.fractionLength(0))) } ?? Text("Not available"))
    }
}

/// How many sessions the agent has open, on a neutral fill; a small blue dot when one of them
/// needs you (the list filter's rule). Shown only with something open.
private struct OpenSessionsBadge: View {
    let count: Int
    let needsYou: Bool

    /// A neutral gray that a white number reads on, light or dark.
    private static var fill: Color {
        #if os(iOS)
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.47, alpha: 0.32) : .systemGray2 })
        #else
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.47, alpha: 0.32) : .systemGray })
        #endif
    }

    var body: some View {
        Text(count, format: .number)
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 22)
            .background(Self.fill, in: Capsule())
            // The dot is cut out of the badge first, so a 2 pt ring of whatever is behind it (the
            // cell, in the list and in the sidebar alike) sets it apart.
            .overlay(alignment: .topTrailing) {
                if needsYou { Circle().frame(width: 12, height: 12).offset(x: 4, y: -4).blendMode(.destinationOut) }
            }
            .compositingGroup()
            .overlay(alignment: .topTrailing) {
                if needsYou { Circle().fill(Color.blue).frame(width: 8, height: 8).offset(x: 2, y: -2) }
            }
            .accessibilityElement()
            .accessibilityLabel(needsYou ? Text("\(count) open, something needs you") : Text("\(count) open"))
    }
}

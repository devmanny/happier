import HappierKit
import SwiftUI

/// "Agents" atop the session list: one compact row per agent with its open sessions, the weekly
/// usage of its account and how many need you. Tapping one shows its card (a sheet on iPhone, a
/// popover on iPad and Mac). The order is the account's (`AccountSettings.agentOrder`): Edit, or
/// touching and holding a row, drags it into place. Nothing shows without agents.
struct AgentsSection: View {
    /// The list's sessions (throttled by the list), every state but archived.
    let sessions: [Session]
    /// Opens a session the way the list does (the drawer's `onOpen`, or the split view's selection).
    let open: (String) -> Void
    /// "New Session with…": the list presents the new-session sheet for this agent.
    let newSession: (AgentProfile) -> Void
    /// Edit shows the rows' drag handles. The list holds it: the edit mode only reaches the rows
    /// set on the whole list.
    @Binding var editing: Bool
    @Environment(HappierStore.self) private var store

    private var savedOrder: [String] { store.accountSettings?.agentOrder ?? [] }
    private var profiles: [AgentProfile] { AgentRoster.ordered(store.agentProfiles, by: savedOrder) }

    var body: some View {
        let profiles = profiles
        if !profiles.isEmpty {
            Section {
                // One rounded card of rows, as in Settings, whatever the list's own style.
                ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                    AgentRow(profile: profile, sessions: sessions, open: open, newSession: newSession)
                        .listRowInsets(EdgeInsets(top: 0, leading: AgentsCard.inset + AgentsCard.padding,
                                                  bottom: 0, trailing: AgentsCard.inset + AgentsCard.padding))
                        .listRowSeparator(.hidden)
                        .listRowBackground(AgentsCard.RowBackground(isFirst: index == 0, isLast: index == profiles.count - 1))
                }
                .onMove { offsets, destination in
                    let next = AgentRoster.order(afterMoving: offsets, to: destination, in: profiles.map(\.id), saved: savedOrder)
                    AppHaptics.selection()
                    Task { await store.updateAccountSettings { $0.delta(agentOrder: next) } }
                }
            } header: {
                header
            }
            // Readings for agents with none shown yet: one read of one session each, when the section
            // appears or an agent gets a session to read from.
            .task(id: usageSources(profiles).map(\.id)) { await readMissingUsage(profiles) }
        }
    }

    private var header: some View {
        HStack {
            Text("Agents")
            Spacer()
            #if os(iOS)
            Button(editing ? "Done" : "Edit") {
                AppHaptics.light()
                withAnimation(.smooth(duration: 0.2)) { editing.toggle() }
            }
            .font(.subheadline.weight(editing ? .semibold : .regular))
            .textCase(nil)
            .disabled(store.accountSettings == nil)
            .accessibilityIdentifier("agents-edit")
            #endif
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

/// One agent: the emoji and name over "4 open · 1 working", then its provider logo, its account's
/// weekly usage ring and, only when something needs you, an amber count.
private struct AgentRow: View {
    let profile: AgentProfile
    let sessions: [Session]
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
    @State private var showCard = false

    var body: some View {
        Button {
            AppHaptics.selection()
            showCard = true
        } label: {
            // "Working" fades after two minutes without news, as in the session rows.
            TimelineView(.periodic(from: .now, by: onScreen ? 30 : 3_600)) { context in
                label(AgentRoster.summary(of: profile, sessions: sessions, context: SessionListFilter.Context(tasks: store.tasks),
                                          now: store.presenceDate(context.date), usage: { store.usage(for: $0.id) }))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("agent-row-\(profile.id)")
        .popover(isPresented: $showCard) {
            AgentCard(profile: profile, sessions: sessions) { sessionId in
                showCard = false
                open(sessionId)
            } newSession: {
                showCard = false
                newSession(profile)
            }
            .presentationDetents([.medium, .large])
            #if os(macOS)
            .frame(width: 360, height: 460)
            #else
            .frame(minWidth: 340, minHeight: 420)
            #endif
        }
    }

    private func label(_ summary: AgentSummary) -> some View {
        HStack(spacing: 8) {
            AgentIcon(emoji: profile.emoji)
                .padding(.trailing, AgentsCard.iconGap - 8)
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
        .padding(.vertical, 7)
        .frame(minHeight: 44)
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

/// The section's look: one rounded card of rows on the grouped cell color, inset from the list's
/// edges, with separators that start after the icon, as in Settings.
private enum AgentsCard {
    static let inset: CGFloat = 16
    static let padding: CGFloat = 10
    static let iconSize: CGFloat = 30
    static let iconGap: CGFloat = 12
    static let radius: CGFloat = 14

    /// The grouped cell color in dark mode; in light mode a light gray, since the drawer itself is
    /// white and a white card wouldn't show on it.
    static var cellColor: Color {
        #if os(iOS)
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .secondarySystemGroupedBackground : .systemGray6 })
        #else
        Color(nsColor: .quaternarySystemFill)
        #endif
    }

    /// The open-sessions badge: a neutral gray that a white number reads on, light or dark.
    static var badgeColor: Color {
        #if os(iOS)
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.47, alpha: 0.32) : .systemGray2 })
        #else
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.47, alpha: 0.32) : .systemGray })
        #endif
    }

    static var separatorColor: Color {
        #if os(iOS)
        Color(uiColor: .separator)
        #else
        Color(nsColor: .separatorColor)
        #endif
    }

    struct RowBackground: View {
        let isFirst: Bool
        let isLast: Bool

        var body: some View {
            let r = AgentsCard.radius
            UnevenRoundedRectangle(topLeadingRadius: isFirst ? r : 0, bottomLeadingRadius: isLast ? r : 0,
                                   bottomTrailingRadius: isLast ? r : 0, topTrailingRadius: isFirst ? r : 0,
                                   style: .continuous)
                .fill(AgentsCard.cellColor)
                .overlay(alignment: .top) {
                    if !isFirst {
                        Rectangle().fill(AgentsCard.separatorColor).frame(height: 0.5)
                            .padding(.leading, AgentsCard.padding + AgentsCard.iconSize + AgentsCard.iconGap)
                    }
                }
                .padding(.horizontal, AgentsCard.inset)
        }
    }
}

/// The agent's icon, as in Settings: its emoji centered on a gray rounded square.
private struct AgentIcon: View {
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
            .frame(width: AgentsCard.iconSize, height: AgentsCard.iconSize)
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

/// The account's weekly usage on a gray track: primary, red from 80 % used (`isNearLimit`, the
/// rule every usage ring and bar draws); an empty track without a reading.
private struct AgentUsageRing: View {
    let meter: ProviderUsage.Meter?
    var diameter: CGFloat = 20

    private var fraction: Double? { meter.map { $0.usedPercent / 100 } }

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 2.6)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.02, min(fraction, 1)))
                    .stroke(meter?.isNearLimit == true ? Color.red : Color.primary,
                            style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
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

    var body: some View {
        Text(count, format: .number)
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 22)
            .background(AgentsCard.badgeColor, in: Capsule())
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

/// The agent's card: who it is and on which account, the account's weekly usage, its open
/// sessions (tap to open one) and a new session with it.
private struct AgentCard: View {
    let profile: AgentProfile
    let sessions: [Session]
    let open: (String) -> Void
    let newSession: () -> Void
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = store.presenceDate(context.date)
            let filterContext = SessionListFilter.Context(tasks: store.tasks)
            let summary = AgentRoster.summary(of: profile, sessions: sessions, context: filterContext, now: now,
                                              usage: { store.usage(for: $0.id) })
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        usage(summary.weekly)
                        sessionList(summary, context: filterContext, now: now)
                    }
                    .padding(20)
                }
                Button {
                    AppHaptics.light()
                    newSession()
                } label: {
                    Label("New Session with \(profile.name)", systemImage: "plus")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .accessibilityIdentifier("agent-new-session")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AgentEmoji(emoji: profile.emoji, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.title3.weight(.semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    ProviderLogo(providerId: profile.providerId, size: 13)
                    Text(accountLine).lineLimit(1)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            #if os(iOS)
            Button {
                AppHaptics.light()
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel(Text("Close"))
            #endif
        }
    }

    /// "Claude Code · Claude DevManny": the engine and the account it's tied to.
    private var accountLine: String {
        let provider = Agent.displayNames[profile.providerId] ?? profile.providerId
        let account = profile.account.label.trimmingCharacters(in: .whitespaces)
        return account.isEmpty ? provider : "\(provider) · \(account)"
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

    @ViewBuilder
    private func sessionList(_ summary: AgentSummary, context: SessionListFilter.Context, now: Date) -> some View {
        Text("Open Sessions · \(summary.open)")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
        if summary.sessions.isEmpty {
            Text("No open sessions").font(.subheadline).foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(summary.sessions) { session in
                    Button {
                        AppHaptics.selection()
                        open(session.id)
                    } label: {
                        sessionRow(session, state: AgentRoster.state(of: session, context: context, now: now))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("agent-session-\(session.id)")
                    if session.id != summary.sessions.last?.id { Divider().padding(.leading, 30) }
                }
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func sessionRow(_ session: Session, state: AgentSummary.SessionState) -> some View {
        HStack(spacing: 10) {
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
                Text(session.listDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

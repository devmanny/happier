import HappierKit
import SwiftUI

/// The sessions an agent's reply names (`MarkdownSegments.Segment.sessions`), one card each, stacked.
struct SessionReferenceStack: View {
    let ids: [String]
    /// Drawn inside a message bubble (`MarkdownText`) rather than between bubbles.
    var inBubble = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(ids.enumerated()), id: \.offset) { _, id in
                SessionReferenceCard(sessionId: id, inBubble: inBubble)
            }
        }
    }
}

/// A session an agent's reply names, as a card in its chat: the avatar of the engine it runs on,
/// its title, what its thread says it is doing (else its folder), and where it stands on the right,
/// read by the same rule as the agent's own card (`AgentRoster.line`) and kept live ("Working" fades
/// after two minutes without news). A tap opens it (`HappierStore.openRelatedSession`), including one
/// this device doesn't list: it is fetched, or reported gone.
struct SessionReferenceCard: View {
    let sessionId: String
    var inBubble = false
    /// Optional, as in `SessionAvatar`: previews draw outside the app's environment.
    @Environment(HappierStore.self) private var store: HappierStore?
    @Environment(\.colorScheme) private var colorScheme

    private static let corner: CGFloat = 16

    var body: some View {
        Button {
            AppHaptics.selection()
            guard let store else { return }
            Task { await store.openRelatedSession(sessionId) }
        } label: {
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                card(at: timeline.date)
            }
        }
        .buttonStyle(.pressable)
        .accessibilityHint(Text("Opens that session"))
        .accessibilityIdentifier("session-card-\(sessionId)")
    }

    private func card(at date: Date) -> some View {
        let session = store?.sessions[sessionId]
        let line = session.flatMap { session in
            store.map { store in
                AgentRoster.line(of: session, memory: session.agentIdentity.flatMap { store.agentMemories[$0.id] },
                                 context: SessionListFilter.Context(tasks: store.tasks), now: store.presenceDate(date))
            }
        }
        return HStack(spacing: 10) {
            AgentAvatar(agentId: session?.agentId, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: line?.title ?? String(localized: "Session"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(line == nil ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
                    .lineLimit(1)
                if let line, !line.detail.isEmpty {
                    Text(verbatim: line.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(line.doing ? .tail : .head)
                } else if line == nil {
                    Text("Not in your list")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let line {
                state(line)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 320, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .overlay {
            if inBubble {
                RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText(line)))
    }

    @ViewBuilder
    private func state(_ line: AgentRoster.SessionLine) -> some View {
        switch line.state {
        case .working: Text("Working").foregroundStyle(Color.userBubble)
        case .needsYou: Text("Needs you").foregroundStyle(Color.orange)
        case .idle: Text(line.lastActivity, format: .relative(presentation: .named)).foregroundStyle(.secondary)
        }
    }

    /// Between bubbles it is one of them; inside one (the session chat) a quieter panel, like a table.
    private var fill: Color {
        inBubble ? Color.black.opacity(colorScheme == .dark ? 0.28 : 0.05) : Color.agentBubble
    }

    private func accessibilityText(_ line: AgentRoster.SessionLine?) -> String {
        guard let line else { return String(localized: "Session not in your list") }
        let state = switch line.state {
        case .working: String(localized: "Working")
        case .needsYou: String(localized: "Needs you")
        case .idle: line.lastActivity.formatted(.relative(presentation: .named))
        }
        return [String(localized: "Session \(line.title)"), line.detail, state].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

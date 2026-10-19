import HappierKit
import SwiftUI

/// One agent turn's work folded into a single line ("Worked for 3m 12s · 14 steps"); tap to see
/// every step. While the turn runs it shows a spinner and the step in progress.
struct WorkRow: View {
    let steps: [ChatItem]
    let inProgress: Bool
    let startedAt: Date?
    let endedAt: Date?
    let sessionId: String
    @State private var expanded = false

    private var failed: Bool {
        steps.contains { if case .toolCall(let tool) = $0 { tool.state == .error } else { false } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.smooth(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if inProgress {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "checkmark.circle")
                            .font(.caption)
                    }
                    Text(headline)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    if inProgress, !expanded, let current = steps.last.map(Self.summary) {
                        Text(current)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer(minLength: 4)
                    if failed {
                        Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.red)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(headline)
            .accessibilityHint(expanded ? "Hides the steps" : "Shows every step")

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(ChatRow.groupTools(steps)) { row in
                        switch row {
                        case .item(let item): ChatItemView(item: item, sessionId: sessionId, tail: false)
                        case .tools(let tools, _): ToolGroupRow(tools: tools, sessionId: sessionId)
                        case .work: EmptyView()
                        }
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.quaternary).frame(width: 1).padding(.leading, 2)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.trailing, 40)
    }

    private var headline: String {
        let count = steps.count == 1 ? String(localized: "1 step") : String(localized: "\(steps.count) steps")
        if inProgress { return String(localized: "Working · \(count)") }
        let seconds = ChatRow.workDuration(steps: steps, startedAt: startedAt, endedAt: endedAt)
        guard seconds >= 1 else { return String(localized: "Worked · \(count)") }
        let duration = Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
        return String(localized: "Worked for \(duration) · \(count)")
    }

    private static func summary(_ step: ChatItem) -> String {
        switch step {
        case .toolCall(let tool): [ToolPresentation.name(tool.name), ToolPresentation.summary(tool)].compactMap { $0 }.joined(separator: " ")
        case .agentText(let text): text.isThinking ? String(localized: "Thinking") : String(text.text.prefix(80))
        case .userText(let text): String(text.text.prefix(80))
        case .event(let event): event.kind
        }
    }
}

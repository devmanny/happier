import Foundation

/// A rendered transcript row. Each agent turn folds its work (thinking, narration, tools, events)
/// into one `.work` line and leaves only the final answer visible, like the Claude and ChatGPT
/// apps; inside an expanded `.work`, consecutive tools collapse into `.tools`.
public enum ChatRow: Identifiable, Sendable, Equatable {
    case item(ChatItem)
    /// A turn's folded steps. Identified by its first step so expansion survives the turn growing.
    case work(steps: [ChatItem], id: String, inProgress: Bool)
    /// Consecutive tool calls (only inside an expanded `.work`).
    case tools([ToolCall], id: String)

    public var id: String {
        switch self {
        case .item(let item): item.id
        case .work(_, let id, _): id
        case .tools(_, let id): id
        }
    }

    public var createdAt: Date {
        switch self {
        case .item(let item): item.createdAt
        case .work(let steps, _, _): steps.first?.createdAt ?? .distantPast
        case .tools(let tools, _): tools.last?.createdAt ?? .distantPast
        }
    }

    /// Transcript rows with every agent turn folded. `working` means the latest turn is still
    /// running, so it has no final answer yet.
    public static func rows(from items: [ChatItem], working: Bool) -> [ChatRow] {
        var rows: [ChatRow] = []
        var turn: [ChatItem] = []

        func flush(isLast: Bool) {
            defer { turn = [] }
            guard !turn.isEmpty else { return }
            let inProgress = isLast && working
            let approvals = turn.filter(\.awaitsApproval)
            var steps = turn.filter { !$0.awaitsApproval }
            var final: ChatItem?
            if !inProgress, let index = steps.lastIndex(where: \.isAnswer) {
                final = steps.remove(at: index)
            }
            if !steps.isEmpty {
                rows.append(.work(steps: steps, id: "work:\(steps[0].id)", inProgress: inProgress))
            }
            rows += approvals.map(ChatRow.item)
            if let final { rows.append(.item(final)) }
        }

        for item in items {
            if case .userText = item {
                flush(isLast: false)
                rows.append(.item(item))
            } else {
                turn.append(item)
            }
        }
        flush(isLast: true)
        return rows
    }

    /// Steps of an expanded `.work`, with runs of two or more tools collapsed into `.tools`.
    public static func groupTools(_ steps: [ChatItem]) -> [ChatRow] {
        var rows: [ChatRow] = []
        var run: [ToolCall] = []
        func flush() {
            if run.count >= 2 {
                rows.append(.tools(run, id: "tools:\(run[0].itemId)"))
            } else {
                rows += run.map { .item(.toolCall($0)) }
            }
            run = []
        }
        for step in steps {
            if case .toolCall(let tool) = step { run.append(tool) } else {
                flush()
                rows.append(.item(step))
            }
        }
        flush()
        return rows
    }

    /// Seconds the agent worked: from the user's message to the end of the turn.
    public static func workDuration(steps: [ChatItem], startedAt: Date?, endedAt: Date?) -> TimeInterval {
        guard let start = startedAt ?? steps.first?.createdAt, let end = endedAt ?? steps.last?.createdAt else { return 0 }
        return max(0, end.timeIntervalSince(start))
    }
}

private extension ChatItem {
    var awaitsApproval: Bool {
        if case .toolCall(let tool) = self { return tool.permission?.status == .pending }
        return false
    }

    /// A visible reply: agent text that isn't thinking.
    var isAnswer: Bool {
        if case .agentText(let text) = self { return !text.isThinking }
        return false
    }
}

import Foundation

/// A rendered transcript row. The agent's messages always show; the steps between them (thinking,
/// tools, events) fold into one `.work` line each, like the Claude app. Inside an expanded `.work`,
/// consecutive tools collapse into `.tools`.
public enum ChatRow: Identifiable, Sendable, Equatable {
    case item(ChatItem)
    /// Folded steps between two messages. Identified by its first step so expansion survives the
    /// run growing.
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

    /// Transcript rows with every agent turn's steps folded. `working` means the latest turn is
    /// still running, so its latest steps are in progress.
    public static func rows(from items: [ChatItem], working: Bool) -> [ChatRow] {
        var rows: [ChatRow] = []
        var turn: [ChatItem] = []

        func flush(isLast: Bool) {
            defer { turn = [] }
            var run: [ChatItem] = []
            func fold(inProgress: Bool) {
                guard !run.isEmpty else { return }
                rows.append(.work(steps: run, id: "work:\(run[0].id)", inProgress: inProgress))
                run = []
            }
            let lastMessage = turn.lastIndex(where: \.isMessage)
            for (index, item) in turn.enumerated() {
                if item.isMessage {
                    fold(inProgress: false)
                    rows.append(.item(item))
                } else if item.staysVisible {
                    // Questions keep their place after answering; other approvals stay visible
                    // while waiting. The steps before them keep folding in place.
                    fold(inProgress: isLast && working && index > (lastMessage ?? -1))
                    rows.append(.item(item))
                } else {
                    run.append(item)
                }
            }
            fold(inProgress: isLast && working)
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
            if case .toolCall(let tool) = step, !tool.isQuestion { run.append(tool) } else {
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
    var staysVisible: Bool {
        if case .toolCall(let tool) = self { return tool.isQuestion || tool.permission?.status == .pending }
        return false
    }

    /// Agent text that isn't thinking: always shown.
    var isMessage: Bool {
        if case .agentText(let text) = self { return !text.isThinking }
        return false
    }
}

/// How much of the transcript the conversation draws: the newest rows only. Every update of a
/// working session (several per second) re-lays out what is drawn, so a long session must not
/// draw its whole history; scrolling up to the top widens the window, loading more if needed.
public enum ChatWindow {
    public static let initial = 40
    public static let step = 40

    public static func visible(_ rows: [ChatRow], limit: Int) -> ArraySlice<ChatRow> {
        rows.suffix(max(limit, 0))
    }

    /// The window wide enough to draw `id` (a search match) with a few rows above it.
    public static func limit(including id: String, in rows: [ChatRow], current: Int) -> Int {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return current }
        return max(current, rows.count - index + 10)
    }
}

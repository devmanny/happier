import Foundation

/// A rendered transcript row: one item, or a run of consecutive tool calls collapsed into one line
/// (the official UI's "Tool calls · N" group). Tools awaiting approval are never grouped.
public enum ChatRow: Identifiable, Sendable, Equatable {
    case item(ChatItem)
    /// Identified by its first tool, so the group keeps its identity (and expansion) as it grows.
    case tools([ToolCall], id: String)

    public var id: String {
        switch self {
        case .item(let item): item.id
        case .tools(_, let id): id
        }
    }

    public var createdAt: Date {
        switch self {
        case .item(let item): item.createdAt
        case .tools(let tools, _): tools.last?.createdAt ?? .distantPast
        }
    }

    public static func rows(from items: [ChatItem]) -> [ChatRow] {
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
        for item in items {
            if case .toolCall(let tool) = item, tool.permission?.status != .pending {
                run.append(tool)
            } else {
                flush()
                rows.append(.item(item))
            }
        }
        flush()
        return rows
    }
}

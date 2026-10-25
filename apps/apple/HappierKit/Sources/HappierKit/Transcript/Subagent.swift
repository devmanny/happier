import Foundation

/// A subagent the agent started (Claude's `Agent`/`Task`, the generic `SubAgent`), with where it
/// stands (`deriveSubAgentSidechainSubagents.ts`). Its own messages form a separate thread, keyed
/// by the id of the tool call that started it.
public struct Subagent: Identifiable, Hashable, Sendable {
    public enum Status: Equatable, Sendable { case running, finished, failed }

    /// The starting tool call's id, which is also the thread's `sidechainId`.
    public let id: String
    public let title: String
    /// `subagent_type`, e.g. "Explore".
    public let kind: String?
    public let startedAt: Date
    public let status: Status
    /// The latest message of its own thread, while known.
    public let lastActivityAt: Date?

    static let toolNames: Set<String> = ["SubAgent", "Task", "Agent"]

    /// The subagents among the conversation's tool calls. A background subagent's tool call returns
    /// as soon as it is launched; it is running until its own thread ends with a final answer.
    static func list(in items: [ChatItem], threads: [TranscriptMessage]) -> [Subagent] {
        var latest: [String: TranscriptMessage] = [:]
        for row in threads {
            guard let id = row.sidechainId else { continue }
            if let known = latest[id], known.seq > row.seq { continue }
            latest[id] = row
        }
        return items.compactMap { item -> Subagent? in
            guard case .toolCall(let tool) = item, toolNames.contains(tool.name) else { return nil }
            let input = tool.input
            let title = ["name", "label", "description", "subagent_type"].lazy
                .compactMap { input[$0]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? tool.name
            let tail = latest[tool.id]
            let status: Status = switch tool.state {
            case .error: .failed
            case .running: .running
            case .completed: isLaunchAcknowledgement(tool.result) && !(tail.map(isFinalAnswer) ?? false) ? .running : .finished
            }
            return Subagent(id: tool.id, title: title, kind: input["subagent_type"]?.stringValue, startedAt: tool.createdAt,
                            status: status, lastActivityAt: tail?.createdAt)
        }
    }

    /// Claude's answer to launching a background agent (`isClaudeAsyncAgentLaunchToolResult`).
    static func isLaunchAcknowledgement(_ result: JSONValue?) -> Bool {
        guard let result else { return false }
        if result["status"]?.stringValue == "async_launched" || result["isAsync"]?.boolValue == true { return true }
        return result.flattenedText.hasPrefix("Async agent launched")
    }

    /// The thread's last row is the agent's final answer (Claude ends its turn with text only).
    static func isFinalAnswer(_ row: TranscriptMessage) -> Bool {
        let data = row.record["content"]?["data"]
        guard data?["type"]?.stringValue == "assistant", let message = data?["message"] else { return false }
        if message["stop_reason"]?.stringValue == "end_turn" { return true }
        return false
    }
}

extension Session {
    /// Whether the daemon keeps count of what runs in the background for this session; its count
    /// is then the truth, since a subagent's own thread may not have been read to its end.
    public var reportsBackgroundActivity: Bool { runtimeActivityRevision > 0 }
}

extension Subagent {
    /// As the session sees it: nothing is running when the daemon counts nothing in the background.
    public func settled(by session: Session?) -> Subagent {
        guard status == .running, let session, session.reportsBackgroundActivity, session.backgroundActivityCount == 0 else { return self }
        return Subagent(id: id, title: title, kind: kind, startedAt: startedAt, status: .finished, lastActivityAt: lastActivityAt)
    }
}

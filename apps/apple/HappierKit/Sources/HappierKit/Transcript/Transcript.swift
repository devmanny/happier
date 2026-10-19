import Foundation

/// Session transcript state: raw rows in, rendered `ChatItem`s out.
///
/// A compact port of the UI pipeline (`typesRaw/normalize.ts` → `reducer/reducer.ts`) covering the
/// main transcript: one item per content block, thinking/stream merging, tool-call/result pairing,
/// permissions from `agentState`, and optimistic pending user messages. Sidechain rows (sub-agent
/// work under a Task tool) are kept out of the main list, as in the UI.
///
/// Items are rebuilt from the retained rows on every change; this keeps the reduction a pure
/// function of (rows, agentState, pending) with no incremental-state drift.
public struct Transcript: Sendable {
    public private(set) var items: [ChatItem] = []
    public private(set) var pendingRequests: [PendingRequest] = []
    public private(set) var maxSeq: Int = 0
    public private(set) var minSeq: Int?

    private var rows: [String: TranscriptMessage] = [:]
    private var agentState: JSONValue = .null
    private var pending: [(localId: String, text: String, attachments: [String], createdAt: Date)] = []

    public init() {}

    public var isEmpty: Bool { rows.isEmpty && pending.isEmpty }

    public mutating func apply(_ messages: [TranscriptMessage]) {
        guard !messages.isEmpty else { return }
        for message in messages { rows[message.id] = message }
        maxSeq = rows.values.map(\.seq).max() ?? 0
        minSeq = rows.values.map(\.seq).min()
        let committed = Set(rows.values.compactMap(\.localId))
        pending.removeAll { committed.contains($0.localId) }
        rebuild()
    }

    public mutating func apply(agentState: JSONValue) {
        self.agentState = agentState
        rebuild()
    }

    public mutating func addPending(localId: String, text: String, attachments: [String] = [], at date: Date = .now) {
        pending.append((localId, text, attachments, date))
        rebuild()
    }

    public mutating func removePending(localId: String) {
        pending.removeAll { $0.localId == localId }
        rebuild()
    }

    public var pendingPermissions: [PendingRequest] { pendingRequests }

    // MARK: - Reduction

    private mutating func rebuild() {
        var builder = Builder()
        for row in rows.values.sorted(by: { ($0.seq, $0.createdAt) < ($1.seq, $1.createdAt) }) {
            builder.add(row)
        }
        pendingRequests = Self.pendingRequests(from: agentState)
        builder.applyPermissions(agentState: agentState, pending: pendingRequests)
        for p in pending where !builder.seenLocalIds.contains(p.localId) {
            builder.items.append(.userText(UserText(id: UserText.stableId(localId: p.localId), text: p.text, createdAt: p.createdAt, localId: p.localId, isPending: true, attachments: p.attachments)))
        }
        items = builder.items
    }

    static let userActionTools: Set<String> = ["AskUserQuestion", "ask_user_question", "ExitPlanMode", "exit_plan_mode", "AcpHistoryImport"]

    static func pendingRequests(from agentState: JSONValue) -> [PendingRequest] {
        guard let requests = agentState["requests"]?.objectValue else { return [] }
        return requests.map { id, request in
            let tool = request["tool"]?.stringValue ?? "unknown"
            let kind: ToolPermission.Kind = switch request["kind"]?.stringValue {
            case "user_action": .userAction
            case "permission": .permission
            default: userActionTools.contains(tool) ? .userAction : .permission
            }
            return PendingRequest(
                id: id, tool: tool, arguments: request["arguments"] ?? .null, kind: kind,
                createdAt: request["createdAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) })
        }
        .sorted { ($0.createdAt ?? .distantPast, $0.id) < ($1.createdAt ?? .distantPast, $1.id) }
    }
}

// MARK: - Builder

private struct Builder {
    var items: [ChatItem] = []
    var seenLocalIds: Set<String> = []
    private var toolIndex: [String: Int] = [:]
    private var bufferedResults: [String: (content: JSONValue, isError: Bool)] = [:]
    private var segmentIndex: [String: Int] = [:]
    private var streamIndex: [String: Int] = [:]

    mutating func add(_ row: TranscriptMessage) {
        let blocks = Normalizer.blocks(for: row.record)
        if let localId = row.localId, case .userText? = blocks.first {
            guard seenLocalIds.insert(localId).inserted else { return }
        }
        let meta = row.record["meta"]
        for (index, block) in blocks.enumerated() {
            let itemId = "\(row.id):\(index)"
            switch block {
            case .userText(let text, let attachments):
                var user = UserText(id: row.localId.map(UserText.stableId) ?? itemId, text: text, createdAt: row.createdAt,
                                    localId: row.localId, isPending: false, attachments: attachments)
                user.seq = row.seq
                items.append(.userText(user))
            case .text(let text, let thinking):
                addText(text, thinking: thinking, itemId: itemId, createdAt: row.createdAt, seq: row.seq, meta: meta)
            case .toolCall(let id, let name, let input, let title):
                addTool(id: id, name: name, input: input, title: title, itemId: itemId, createdAt: row.createdAt)
            case .toolResult(let id, let content, let isError, let append):
                addResult(id: id, content: content, isError: isError, append: append)
            case .event(let kind, let data):
                items.append(.event(TranscriptEvent(id: itemId, kind: kind, data: data, createdAt: row.createdAt)))
            }
        }
    }

    private mutating func addText(_ text: String, thinking: Bool, itemId: String, createdAt: Date, seq: Int, meta: JSONValue?) {
        if let segment = meta?["happierStreamSegmentV1"]?["segmentLocalId"]?.stringValue {
            let isThinking = thinking || meta?["happierStreamSegmentV1"]?["segmentKind"]?.stringValue == "thinking"
            let item = ChatItem.agentText(AgentText(id: "seg:\(segment)", seq: seq, text: text, isThinking: isThinking, createdAt: createdAt))
            if let index = segmentIndex[segment] { items[index] = item } else {
                segmentIndex[segment] = items.count
                items.append(item)
            }
            return
        }
        if let key = meta?["happierStreamKey"]?.stringValue {
            if let index = streamIndex[key], case .agentText(var existing) = items[index] {
                existing.text += text
                items[index] = .agentText(existing)
            } else {
                streamIndex[key] = items.count
                items.append(.agentText(AgentText(id: itemId, seq: seq, text: text, isThinking: thinking, createdAt: createdAt)))
            }
            return
        }
        if thinking, case .agentText(var last)? = items.last, last.isThinking {
            last.text += text
            items[items.count - 1] = .agentText(last)
            return
        }
        items.append(.agentText(AgentText(id: itemId, seq: seq, text: text, isThinking: thinking, createdAt: createdAt)))
    }

    private mutating func addTool(id: String, name: String, input: JSONValue, title: String?, itemId: String, createdAt: Date) {
        guard toolIndex[id] == nil else { return }
        var tool = ToolCall(id: id, itemId: itemId, name: name, input: input, title: title, state: .running, result: nil, permission: nil, createdAt: createdAt)
        if let buffered = bufferedResults.removeValue(forKey: id) {
            tool.result = buffered.content
            tool.state = buffered.isError ? .error : .completed
        }
        toolIndex[id] = items.count
        items.append(.toolCall(tool))
    }

    private mutating func addResult(id: String, content: JSONValue, isError: Bool, append: Bool) {
        guard let index = toolIndex[id], case .toolCall(var tool) = items[index] else {
            bufferedResults[id] = (content, isError)
            return
        }
        if append, let previous = tool.result {
            tool.result = .string(previous.flattenedText + content.flattenedText)
        } else {
            tool.result = content
            tool.state = isError ? .error : .completed
        }
        items[index] = .toolCall(tool)
    }

    /// Phase 0 of the UI reducer: attach `agentState` requests to tool calls by id, then by
    /// (name, arguments); pending requests without a transcript row get a placeholder.
    mutating func applyPermissions(agentState: JSONValue, pending: [PendingRequest]) {
        for request in pending {
            let permission = ToolPermission(id: request.id, status: .pending, kind: request.kind, reason: nil, decision: nil)
            if let index = matchTool(id: request.id, name: request.tool, arguments: request.arguments) {
                update(index) { $0.permission = permission }
            } else {
                toolIndex[request.id] = items.count
                items.append(.toolCall(ToolCall(
                    id: request.id, itemId: "request:\(request.id)", name: request.tool, input: request.arguments,
                    title: request.arguments["description"]?.stringValue, state: .running, result: nil,
                    permission: permission, createdAt: request.createdAt ?? .now)))
            }
        }
        for (id, completed) in agentState["completedRequests"]?.objectValue ?? [:] {
            let tool = completed["tool"]?.stringValue ?? ""
            guard let index = matchTool(id: id, name: tool, arguments: completed["arguments"] ?? .null) else { continue }
            let status = ToolPermission.Status(rawValue: completed["status"]?.stringValue ?? "") ?? .canceled
            let kind: ToolPermission.Kind = completed["kind"]?.stringValue == "user_action" || Transcript.userActionTools.contains(tool) ? .userAction : .permission
            let reason = completed["reason"]?.stringValue
            update(index) { call in
                call.permission = ToolPermission(id: id, status: status, kind: kind, reason: reason, decision: completed["decision"]?.stringValue)
                if status != .approved {
                    call.state = .error
                    if call.result == nil, let reason { call.result = .string(reason) }
                }
            }
        }
    }

    private func matchTool(id: String, name: String, arguments: JSONValue) -> Int? {
        if let index = toolIndex[id] { return index }
        return items.indices.first { index in
            guard case .toolCall(let call) = items[index] else { return false }
            return call.permission == nil && call.name == name && call.input == arguments
        }
    }

    private mutating func update(_ index: Int, _ change: (inout ToolCall) -> Void) {
        guard case .toolCall(var call) = items[index] else { return }
        change(&call)
        items[index] = .toolCall(call)
    }
}

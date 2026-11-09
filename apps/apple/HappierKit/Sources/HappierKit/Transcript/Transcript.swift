import Foundation

/// Session transcript state: raw rows in, rendered `ChatItem`s out.
///
/// A compact port of the UI pipeline (`typesRaw/normalize.ts` → `reducer/reducer.ts`) covering the
/// main transcript: one item per content block, thinking/stream merging, tool-call/result pairing,
/// permissions from `agentState`, and optimistic pending user messages. Sidechain rows (sub-agent
/// work under a Task tool) are kept out of the main list, as in the UI.
///
/// The reduction comes from retained rows. State-only questions already shown stay visible
/// between their reply and the corresponding history row arriving.
public struct Transcript: Sendable {
    public private(set) var items: [ChatItem] = []
    public private(set) var pendingRequests: [PendingRequest] = []
    public private(set) var maxSeq: Int = 0
    public private(set) var minSeq: Int?
    /// How full the agent's context is, from the newest token counts loaded.
    public private(set) var contextUsage: ContextUsage?
    /// Subagents started in this conversation, oldest first.
    public private(set) var subagents: [Subagent] = []
    /// A subagent's own thread instead of the main conversation.
    public let isSidechain: Bool
    /// The newest page has come from the server. Until then the transcript only holds what was
    /// sent from here or pushed live, and catching up from `maxSeq` would skip the history.
    public private(set) var isLoaded = false

    private var rows: [String: TranscriptMessage] = [:]
    /// The reduction of every row so far, in order, kept so newer rows continue it instead of
    /// redoing the whole conversation (several messages a second while an agent streams).
    private var ordered: [TranscriptMessage] = []
    private var reduced: Builder
    private var threads: [TranscriptMessage] = []
    private var agentState: JSONValue = .null
    private var pending: [(localId: String, text: String, attachments: [String], createdAt: Date)] = []

    public init(sidechain: Bool = false) {
        isSidechain = sidechain
        reduced = Builder(sidechain: sidechain)
    }

    public var isEmpty: Bool { rows.isEmpty && pending.isEmpty }

    /// How to bring the conversation up to date.
    public enum Refresh: Equatable, Sendable {
        case newestPage
        case after(Int)
    }

    public var refresh: Refresh { isLoaded ? .after(maxSeq) : .newestPage }

    public mutating func markLoaded() { isLoaded = true }

    public mutating func apply(_ messages: [TranscriptMessage]) {
        guard !messages.isEmpty else { return }
        let newer = messages.sorted(by: Self.inOrder)
        // Rows that only extend the conversation continue its reduction; anything else (an
        // older page, a row seen before, one out of order) reduces it again from the start.
        let extends = newer.allSatisfy { rows[$0.id] == nil }
            && Set(newer.map(\.id)).count == newer.count
            && ordered.last.map { last in Self.inOrder(last, newer[0]) } ?? true
        for message in messages { rows[message.id] = message }
        maxSeq = rows.values.map(\.seq).max() ?? 0
        // Paging back goes by the conversation's own rows, not subagent rows that arrived live.
        minSeq = rows.values.filter { isSidechain || $0.sidechainId == nil }.map(\.seq).min()
        let committed = Set(rows.values.compactMap(\.localId))
        pending.removeAll { committed.contains($0.localId) }
        if extends {
            for row in newer { reduce(row) }
            ordered.append(contentsOf: newer)
            finish()
        } else {
            rebuild()
        }
    }

    /// The agent state last applied (pending permissions come from it).
    var agentStateValue: JSONValue { agentState }

    public mutating func apply(agentState: JSONValue) {
        self.agentState = agentState
        finish()
    }

    public mutating func addPending(localId: String, text: String, attachments: [String] = [], at date: Date = .now) {
        pending.append((localId, text, attachments, date))
        finish()
    }

    public mutating func removePending(localId: String) {
        pending.removeAll { $0.localId == localId }
        finish()
    }

    public var pendingPermissions: [PendingRequest] { pendingRequests }

    // MARK: - Reduction

    private static func inOrder(_ a: TranscriptMessage, _ b: TranscriptMessage) -> Bool {
        (a.seq, a.createdAt) < (b.seq, b.createdAt)
    }

    /// Reduces every row again, from the start.
    private mutating func rebuild() {
        ordered = rows.values.sorted(by: Self.inOrder)
        reduced = Builder(sidechain: isSidechain)
        threads = []
        contextUsage = nil
        for row in ordered { reduce(row) }
        finish()
    }

    /// Continues the reduction with the next row in order.
    private mutating func reduce(_ row: TranscriptMessage) {
        if isSidechain || row.sidechainId == nil { reduced.add(row) }
        if row.sidechainId == nil {
            contextUsage = ContextUsage.latest(in: CollectionOfOne(row.record), startingFrom: contextUsage)
        } else {
            threads.append(row)
        }
    }

    /// What depends on more than the rows (permissions from the agent state, messages still
    /// being sent) goes on a copy of the reduction, so it can continue cleanly.
    private mutating func finish() {
        var builder = reduced
        subagents = isSidechain ? [] : Subagent.list(in: builder.items, threads: threads)
        pendingRequests = Self.pendingRequests(from: agentState)
        let visibleQuestions = items.compactMap { item -> ToolCall? in
            guard case .toolCall(let tool) = item, tool.isQuestion, tool.itemId.hasPrefix("request:") else { return nil }
            return tool
        }
        builder.applyPermissions(agentState: agentState, pending: pendingRequests, visibleQuestions: visibleQuestions)
        for p in pending where !builder.seenLocalIds.contains(p.localId) {
            builder.items.append(.userText(UserText(id: UserText.stableId(localId: p.localId), text: p.text, createdAt: p.createdAt, localId: p.localId, isPending: true, attachments: p.attachments)))
        }
        items = builder.items
    }

    static let userActionTools: Set<String> = ["AskUserQuestion", "ask_user_question", "ExitPlanMode", "exit_plan_mode", "AcpHistoryImport"]

    /// The agent's latest spoken text (not its thinking), nil before it has said anything.
    public var lastAgentText: String? {
        for item in items.reversed() {
            if case .agentText(let text) = item, !text.isThinking {
                let trimmed = text.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

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
    let sidechain: Bool
    var items: [ChatItem] = []
    var seenLocalIds: Set<String> = []
    private var toolIndex: [String: Int] = [:]
    private var bufferedResults: [String: (content: JSONValue, isError: Bool, structured: JSONValue?)] = [:]
    private var segmentIndex: [String: Int] = [:]
    private var streamIndex: [String: Int] = [:]

    init(sidechain: Bool) {
        self.sidechain = sidechain
    }

    mutating func add(_ row: TranscriptMessage) {
        let blocks = Normalizer.blocks(for: row.record, sidechain: sidechain)
        if let localId = row.localId, case .userText? = blocks.first {
            guard seenLocalIds.insert(localId).inserted else { return }
        }
        let meta = row.record["meta"]
        for (index, block) in blocks.enumerated() {
            let itemId = "\(row.id):\(index)"
            switch block {
            case .userText(let text, let attachments):
                var user = UserText(id: row.localId.map(UserText.stableId) ?? itemId, text: text, createdAt: row.createdAt,
                                    localId: row.localId, isPending: false, files: attachments,
                                    sessionMessageOrigin: row.record["role"]?.stringValue == "user" ? SessionMessageOrigin.parse(meta) : nil)
                user.seq = row.seq
                items.append(.userText(user))
            case .text(let text, let thinking):
                addText(text, thinking: thinking, itemId: itemId, createdAt: row.createdAt, seq: row.seq, meta: meta)
            case .toolCall(let id, let name, let input, let title):
                addTool(id: id, name: name, input: input, title: title, itemId: itemId, createdAt: row.createdAt)
            case .toolResult(let id, let content, let isError, let append, let structured):
                addResult(id: id, content: content, isError: isError, append: append, structured: structured)
            case .event(let kind, let data):
                // A command's model or effort line and the runner's own change line are one change.
                let recent = items.indices.suffix(8)
                if kind == LocalCommandLine.kind, recent.contains(where: { index in
                    if case .event(let other) = items[index], other.kind == "runtime-config-outcome" { LocalCommandLine.repeats(data, outcome: other.data) } else { false }
                }) { continue }
                if kind == "runtime-config-outcome" {
                    let repeated = recent.filter { index in
                        if case .event(let other) = items[index], other.kind == LocalCommandLine.kind { LocalCommandLine.repeats(other.data, outcome: data) } else { false }
                    }
                    for index in repeated.reversed() { removeItem(at: index) }
                }
                items.append(.event(TranscriptEvent(id: itemId, kind: kind, data: data, createdAt: row.createdAt)))
            }
        }
    }

    /// Removes an item, keeping the indexes of the ones after it.
    private mutating func removeItem(at index: Int) {
        items.remove(at: index)
        toolIndex = toolIndex.mapValues { $0 > index ? $0 - 1 : $0 }
        segmentIndex = segmentIndex.mapValues { $0 > index ? $0 - 1 : $0 }
        streamIndex = streamIndex.mapValues { $0 > index ? $0 - 1 : $0 }
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
        insertTool(ToolCall(id: id, itemId: itemId, name: name, input: input, title: title, state: .running, result: nil, permission: nil, createdAt: createdAt), at: items.count)
    }

    private mutating func insertTool(_ original: ToolCall, at index: Int) {
        var tool = original
        if let buffered = bufferedResults.removeValue(forKey: tool.id) {
            tool.result = buffered.content
            tool.structuredResult = buffered.structured
            tool.state = buffered.isError ? .error : .completed
        }
        if index < items.count {
            toolIndex = toolIndex.mapValues { $0 >= index ? $0 + 1 : $0 }
            segmentIndex = segmentIndex.mapValues { $0 >= index ? $0 + 1 : $0 }
            streamIndex = streamIndex.mapValues { $0 >= index ? $0 + 1 : $0 }
        }
        toolIndex[tool.id] = index
        items.insert(.toolCall(tool), at: index)
    }

    private mutating func addResult(id: String, content: JSONValue, isError: Bool, append: Bool, structured: JSONValue?) {
        guard let index = toolIndex[id], case .toolCall(var tool) = items[index] else {
            bufferedResults[id] = (content, isError, structured)
            return
        }
        if append, let previous = tool.result {
            tool.result = .string(previous.flattenedText + content.flattenedText)
        } else {
            tool.result = content
            tool.structuredResult = structured
            tool.state = isError ? .error : .completed
        }
        items[index] = .toolCall(tool)
    }

    /// Phase 0 of the UI reducer: attach `agentState` requests to tool calls by id, then by
    /// (name, arguments); pending requests without a transcript row get a placeholder.
    mutating func applyPermissions(agentState: JSONValue, pending: [PendingRequest], visibleQuestions: [ToolCall]) {
        for request in pending {
            let permission = ToolPermission(id: request.id, status: .pending, kind: request.kind, reason: nil, decision: nil)
            if let index = matchTool(id: request.id, name: request.tool, arguments: request.arguments) {
                update(index) { $0.permission = permission }
            } else {
                insertTool(ToolCall(
                    id: request.id, itemId: "request:\(request.id)", name: request.tool, input: request.arguments,
                    title: request.arguments["description"]?.stringValue, state: .running, result: nil,
                    permission: permission, createdAt: request.createdAt ?? .now), at: items.count)
            }
        }
        for (id, completed) in agentState["completedRequests"]?.objectValue ?? [:] {
            let tool = completed["tool"]?.stringValue ?? ""
            let arguments = completed["arguments"] ?? .null
            // A question already displayed from agentState must not vanish between its reply
            // and the history row arriving. Never inject unseen completed requests into history.
            if matchTool(id: id, name: tool, arguments: arguments) == nil,
               let question = visibleQuestions.first(where: { $0.permission?.id == id && $0.name == tool && $0.input == arguments }) {
                let insertion = items.firstIndex { $0.createdAt > question.createdAt } ?? items.count
                insertTool(question, at: insertion)
            }
            guard let index = matchTool(id: id, name: tool, arguments: arguments) else { continue }
            let status = ToolPermission.Status(rawValue: completed["status"]?.stringValue ?? "") ?? .canceled
            let kind: ToolPermission.Kind = completed["kind"]?.stringValue == "user_action" || Transcript.userActionTools.contains(tool) ? .userAction : .permission
            let reason = completed["reason"]?.stringValue
            update(index) { call in
                call.permission = ToolPermission(id: id, status: status, kind: kind, reason: reason, decision: completed["decision"]?.stringValue,
                                                 answers: StructuredQuestionnaire.decodeAnswers(completed["structuredAnswersV1"] ?? completed["answers"]))
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

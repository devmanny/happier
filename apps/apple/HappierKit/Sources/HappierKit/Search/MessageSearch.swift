import Foundation

/// Search inside every conversation of the account, not just titles. Transcripts are end-to-end
/// encrypted, so the daemon on the user's Mac answers it from its local full-text index
/// (`daemon.memory.search` v2, `packages/protocol/src/memory/memorySearch.ts`); the relay only
/// forwards the encrypted machine RPC.
public enum MessageSearch {
    public static let method = "daemon.memory.search"
    /// Conversation search on one machine (`packages/protocol/src/memory/messageSearchSwitch.ts`):
    /// the daemon owns what "on" means in its settings; the app only switches it.
    static let statusMethod = "daemon.memory.messageSearch.status"
    static let switchMethod = "daemon.memory.messageSearch.set"
    /// Shorter queries match almost everything; the session list keeps filtering titles meanwhile.
    public static let minimumQueryLength = 2
    public static let pageSize = 20

    public struct Segment: Equatable, Hashable, Sendable {
        public let text: String
        public let isMatch: Bool

        public init(text: String, isMatch: Bool) {
            self.text = text
            self.isMatch = isMatch
        }
    }

    public struct Hit: Identifiable, Equatable, Sendable {
        public let sessionId: String
        public let seq: Int
        public let createdAt: Date
        public let fromUser: Bool
        public let snippet: [Segment]
        /// Relevance as its machine ranked it (higher first).
        public let score: Double
        /// As the Mac last saw them; the app's own copy of the session wins when it has one.
        public let title: String?
        public let agentFlavor: String?

        public var id: String { "\(sessionId):\(seq)" }
    }

    /// How much of the history the Mac has read so far (it backfills in the background).
    public struct Coverage: Equatable, Sendable {
        public let messageCount: Int
        public let sessionCount: Int
        /// Sessions the machine has listed so far.
        public let knownSessionCount: Int
        public let pendingSessionCount: Int
        public let backfillComplete: Bool

        /// Share of the known sessions read up to their latest message (0…1).
        public var progress: Double {
            guard knownSessionCount > 0 else { return 0 }
            return min(1, Double(max(0, knownSessionCount - pendingSessionCount)) / Double(knownSessionCount))
        }
    }

    /// Conversation search on one machine, as its daemon reports it.
    public struct Status: Equatable, Sendable {
        public enum State: String, Equatable, Sendable { case off, indexing, ready }
        public let enabled: Bool
        public let state: State
        public let coverage: Coverage?
        /// The local index's size on the machine's disk; nil when there is none.
        public let indexBytes: Int?
    }

    public struct Page: Equatable, Sendable {
        public let hits: [Hit]
        public let nextCursor: String?
        public let coverage: Coverage
    }

    /// Why a Mac can't answer: search is off there (`off`), its CLI predates full-text search
    /// (`outdated`), or the search itself failed.
    public enum Refusal: Equatable, Sendable {
        case off
        case outdated
        case failed(String)
    }

    public enum Answer: Equatable, Sendable {
        case page(Page)
        case refused(Refusal)
    }

    public static func request(query: String, cursor: String?, limit: Int = pageSize) -> JSONValue {
        var request: [String: JSONValue] = [
            "v": 2,
            "query": .string(query.trimmingCharacters(in: .whitespacesAndNewlines)),
            "limit": .number(Double(limit)),
        ]
        if let cursor { request["cursor"] = .string(cursor) }
        return .object(request)
    }

    public static func answer(_ result: JSONValue) -> Answer {
        let unreadable = Answer.refused(.failed(String(localized: "The Mac sent an answer Happier can't read.")))
        switch (result["v"]?.intValue, result["ok"]?.boolValue) {
        case (1, false):
            // A daemon from before v2 reads the request as an invalid v1 query.
            return .refused(.outdated)
        case (2, false):
            switch result["errorCode"]?.stringValue {
            case "memory_disabled", "memory_index_missing": return .refused(.off)
            default: return .refused(.failed(result["error"]?.stringValue ?? String(localized: "The search failed on the Mac.")))
            }
        case (2, true):
            guard let rawHits = result["hits"]?.arrayValue, let coverage = coverage(result["coverage"]) else { return unreadable }
            return .page(Page(hits: rawHits.compactMap(hit), nextCursor: result["nextCursor"]?.stringValue, coverage: coverage))
        default:
            return unreadable
        }
    }

    public static func switchRequest(enabled: Bool, deleteIndex: Bool) -> JSONValue {
        ["v": 1, "enabled": .bool(enabled), "deleteIndex": .bool(deleteIndex)]
    }

    public static func status(_ result: JSONValue) -> Status? {
        guard result["v"]?.intValue == 1, let enabled = result["enabled"]?.boolValue,
              let state = result["state"]?.stringValue.flatMap(Status.State.init(rawValue:))
        else { return nil }
        return Status(enabled: enabled, state: state, coverage: coverage(result["coverage"]), indexBytes: result["indexBytes"]?.intValue)
    }

    /// Several machines' answers as one list: a message found by more than one appears once,
    /// best-ranked first, newest first among equals.
    public static func merge(_ pages: [[Hit]]) -> [Hit] {
        var best: [String: Hit] = [:]
        for hit in pages.joined() where (best[hit.id]?.score ?? -.infinity) < hit.score { best[hit.id] = hit }
        return best.values.sorted { ($0.score, $0.createdAt, $0.id) > ($1.score, $1.createdAt, $1.id) }
    }

    /// The fallback while the Mac is away: what this device already has loaded, newest first.
    public static func localHits(query: String, transcripts: [(sessionId: String, items: [ChatItem])], limit: Int) -> [Hit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= minimumQueryLength else { return [] }
        var hits: [Hit] = []
        for (sessionId, items) in transcripts {
            for item in items {
                let found: (text: String, seq: Int, fromUser: Bool, createdAt: Date)? = switch item {
                case .userText(let user): user.seq.map { (user.text, $0, true, user.createdAt) }
                case .agentText(let agent): agent.isThinking ? nil : agent.seq.map { (agent.text, $0, false, agent.createdAt) }
                case .toolCall, .event: nil
                }
                guard let found, let snippet = snippet(of: found.text, matching: query) else { continue }
                hits.append(Hit(sessionId: sessionId, seq: found.seq, createdAt: found.createdAt, fromUser: found.fromUser,
                                snippet: snippet, score: 0, title: nil, agentFlavor: nil))
            }
        }
        return Array(hits.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    private static let snippetContext = 60

    /// The text around the first match, every match marked; nil without one.
    static func snippet(of text: String, matching query: String) -> [Segment]? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        guard let first = text.range(of: query, options: options) else { return nil }
        let start = text.index(first.lowerBound, offsetBy: -snippetContext, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(first.upperBound, offsetBy: snippetContext * 2, limitedBy: text.endIndex) ?? text.endIndex
        let window = text[start..<end]
        var segments: [Segment] = []
        if start > text.startIndex { segments.append(Segment(text: "…", isMatch: false)) }
        var cursor = window.startIndex
        while let match = window.range(of: query, options: options, range: cursor..<window.endIndex) {
            if cursor < match.lowerBound { segments.append(Segment(text: String(window[cursor..<match.lowerBound]), isMatch: false)) }
            segments.append(Segment(text: String(window[match]), isMatch: true))
            cursor = match.upperBound
        }
        if cursor < window.endIndex { segments.append(Segment(text: String(window[cursor...]), isMatch: false)) }
        if end < text.endIndex { segments.append(Segment(text: "…", isMatch: false)) }
        return segments
    }

    private static func hit(_ raw: JSONValue) -> Hit? {
        guard let sessionId = raw["sessionId"]?.stringValue, !sessionId.isEmpty, let seq = raw["seq"]?.intValue,
              let createdAtMs = raw["createdAtMs"]?.doubleValue, let rawSnippet = raw["snippet"]?.arrayValue
        else { return nil }
        let snippet = rawSnippet.compactMap { segment -> Segment? in
            guard let text = segment["text"]?.stringValue, !text.isEmpty else { return nil }
            return Segment(text: text, isMatch: segment["match"]?.boolValue == true)
        }
        guard !snippet.isEmpty else { return nil }
        let session = raw["session"] ?? .null
        return Hit(sessionId: sessionId, seq: seq, createdAt: Date(timeIntervalSince1970: createdAtMs / 1000),
                   fromUser: raw["role"]?.stringValue == "user", snippet: snippet, score: raw["score"]?.doubleValue ?? 0,
                   title: nonEmpty(session["title"]?.stringValue), agentFlavor: nonEmpty(session["agent"]?.stringValue))
    }

    private static func coverage(_ raw: JSONValue?) -> Coverage? {
        guard let raw, let messages = raw["messageCount"]?.intValue, let sessions = raw["sessionCount"]?.intValue,
              let known = raw["knownSessionCount"]?.intValue, let pending = raw["pendingSessionCount"]?.intValue,
              let complete = raw["backfillComplete"]?.boolValue
        else { return nil }
        return Coverage(messageCount: messages, sessionCount: sessions, knownSessionCount: known, pendingSessionCount: pending,
                        backfillComplete: complete)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

extension ChatRow {
    /// The row that shows transcript message `seq`: the message's first block, or the folded
    /// steps that hold it. A message this app doesn't draw (the daemon indexes its text anyway)
    /// lands on the closest drawn message before it. Nil while that page of the transcript isn't
    /// loaded (every loaded message is newer).
    public static func rowId(showingSeq seq: Int, in rows: [ChatRow]) -> String? {
        func messageSeq(_ item: ChatItem) -> Int? {
            switch item {
            case .userText(let user): user.seq
            case .agentText(let agent): agent.seq
            case .toolCall, .event: nil
            }
        }
        var closest: (id: String, seq: Int)?
        for row in rows {
            let seqs: [Int] = switch row {
            case .item(let item): messageSeq(item).map { [$0] } ?? []
            case .work(let steps, _, _): steps.compactMap(messageSeq)
            case .tools: []
            }
            if seqs.contains(seq) { return row.id }
            if let before = seqs.filter({ $0 < seq }).max(), before > (closest?.seq ?? Int.min) { closest = (row.id, before) }
        }
        return closest?.id
    }
}

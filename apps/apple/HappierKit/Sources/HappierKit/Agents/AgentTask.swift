import Foundation

/// A task for the user or one of their agents (`packages/protocol/src/tasks/agentTask.ts`), sealed for
/// the account's devices in the UserKVStore under the opaque key `task/<uuid>` (kind `agent_task`).
/// Keys this app doesn't know (the CLI daemon's `notifiedV1`, `createdBy`, …) are kept on rewrite.
public struct AgentTask: Identifiable, Sendable, Equatable {
    public enum Status: String, CaseIterable, Sendable, Identifiable {
        case todo
        case inProgress = "in_progress"
        case blocked
        case inReview = "in_review"
        case done

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .todo: String(localized: "To do")
            case .inProgress: String(localized: "In progress")
            case .blocked: String(localized: "Blocked")
            case .inReview: String(localized: "In review")
            case .done: String(localized: "Done")
            }
        }
    }

    public enum Assignee: Sendable, Equatable, Hashable {
        /// The account's owner.
        case user
        case agent(id: String, name: String?, emoji: String?)

        public static func agent(_ profile: AgentProfile) -> Assignee {
            .agent(id: profile.id, name: profile.name, emoji: profile.emoji)
        }

        public var agentId: String? {
            if case .agent(let id, _, _) = self { return id }
            return nil
        }

        public var label: String {
            switch self {
            case .user: String(localized: "Me")
            case .agent(_, let name, let emoji): [emoji, name].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
            }
        }

        init?(json: JSONValue?) {
            switch json?["kind"]?.stringValue {
            case "user": self = .user
            case "agent":
                guard let id = json?["agentId"]?.stringValue, !id.isEmpty else { return nil }
                self = .agent(id: id, name: json?["name"]?.stringValue, emoji: json?["emoji"]?.stringValue)
            default: return nil
            }
        }

        var json: JSONValue {
            switch self {
            case .user: return ["kind": "user"]
            case .agent(let id, let name, let emoji):
                var object: [String: JSONValue] = ["kind": "agent", "agentId": .string(id)]
                if let name, !name.isEmpty { object["name"] = .string(name) }
                if let emoji, !emoji.isEmpty { object["emoji"] = .string(emoji) }
                return .object(object)
            }
        }
    }

    /// Where the task came from, with a link back to it.
    public struct Source: Sendable, Equatable {
        public static let kinds = ["chat", "email", "session", "other"]
        public var kind: String
        public var label: String?
        public var url: String?
        public var sessionId: String?

        public init(kind: String = "other", label: String? = nil, url: String? = nil, sessionId: String? = nil) {
            self.kind = kind
            self.label = label
            self.url = url
            self.sessionId = sessionId
        }

        init?(json: JSONValue?) {
            guard let json, let kind = json["kind"]?.stringValue, Self.kinds.contains(kind) else { return nil }
            self.init(kind: kind, label: json["label"]?.stringValue, url: json["url"]?.stringValue, sessionId: json["sessionId"]?.stringValue)
        }

        var json: JSONValue {
            var object: [String: JSONValue] = ["kind": .string(kind)]
            if let label, !label.isEmpty { object["label"] = .string(label) }
            if let url, !url.isEmpty { object["url"] = .string(url) }
            if let sessionId, !sessionId.isEmpty { object["sessionId"] = .string(sessionId) }
            return .object(object)
        }
    }

    public struct LogEntry: Sendable, Equatable {
        public var at: Double
        /// Who did it, as written (`{kind:user}`, `{kind:agent,agentId,sessionId?}`, `{kind:session,…}`).
        public var by: JSONValue
        public var text: String?
        public var status: Status?

        public var byUser: Bool { by["kind"]?.stringValue == "user" }

        init?(json: JSONValue) {
            guard let at = json["at"]?.doubleValue, let by = json["by"], by["kind"]?.stringValue != nil else { return nil }
            self.at = at
            self.by = by
            self.text = json["text"]?.stringValue
            self.status = json["status"]?.stringValue.flatMap(Status.init(rawValue:))
        }

        init(at: Double, by: JSONValue, text: String?, status: Status?) {
            self.at = at
            self.by = by
            self.text = text
            self.status = status
        }

        var json: JSONValue {
            var object: [String: JSONValue] = ["at": .number(at), "by": by]
            if let text { object["text"] = .string(text) }
            if let status { object["status"] = .string(status.rawValue) }
            return .object(object)
        }
    }

    public let id: String
    public var title: String
    public var description: String?
    public var assignee: Assignee
    public var status: Status
    public var startAt: Double?
    public var dueAt: Double?
    public var machineId: String?
    public var directory: String?
    public var source: Source?
    /// Sessions that worked on it, on any machine.
    public var threads: [String]
    /// Comments and status changes, oldest first.
    public var log: [LogEntry]
    public var createdAt: Double
    public var updatedAt: Double
    /// The UserKVStore version this copy was read at (-1 for a task not stored yet).
    public var version = -1
    var extra: [String: JSONValue] = [:]

    public init(id: String = UUID().uuidString.lowercased(), title: String, description: String? = nil,
                assignee: Assignee = .user, status: Status = .todo, now: Double = ServerClock.nowMs()) {
        self.id = id.lowercased()
        self.title = title
        self.description = description
        self.assignee = assignee
        self.status = status
        self.threads = []
        self.log = []
        self.createdAt = now
        self.updatedAt = now
        self.extra = ["createdBy": ["kind": "user"]]
    }

    init?(json: JSONValue) {
        guard json["v"]?.intValue == 1, let id = json["id"]?.stringValue, !id.isEmpty,
              let title = json["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              let status = json["status"]?.stringValue.flatMap(Status.init(rawValue:)),
              let assignee = Assignee(json: json["assignee"]) else { return nil }
        self.id = id
        self.title = title
        self.description = json["description"]?.stringValue
        self.assignee = assignee
        self.status = status
        self.startAt = json["startAt"]?.doubleValue
        self.dueAt = json["dueAt"]?.doubleValue
        self.machineId = json["machineId"]?.stringValue
        self.directory = json["directory"]?.stringValue
        self.source = Source(json: json["source"])
        self.threads = json["threads"]?.arrayValue?.compactMap(\.stringValue) ?? []
        self.log = json["log"]?.arrayValue?.compactMap(LogEntry.init(json:)) ?? []
        self.createdAt = json["createdAt"]?.doubleValue ?? 0
        self.updatedAt = json["updatedAt"]?.doubleValue ?? 0
        let known: Set<String> = ["v", "id", "title", "description", "assignee", "status", "startAt", "dueAt", "machineId",
                                  "directory", "source", "threads", "log", "createdAt", "updatedAt"]
        self.extra = (json.objectValue ?? [:]).filter { !known.contains($0.key) }
    }

    var json: JSONValue {
        var object = extra
        object["v"] = 1
        object["id"] = .string(id)
        object["title"] = .string(title)
        object["description"] = description.flatMap { $0.isEmpty ? nil : JSONValue.string($0) }
        object["assignee"] = assignee.json
        object["status"] = .string(status.rawValue)
        object["startAt"] = startAt.map(JSONValue.number)
        object["dueAt"] = dueAt.map(JSONValue.number)
        object["machineId"] = machineId.flatMap { $0.isEmpty ? nil : JSONValue.string($0) }
        object["directory"] = directory.flatMap { $0.isEmpty ? nil : JSONValue.string($0) }
        object["source"] = source?.json
        object["threads"] = .array(threads.map(JSONValue.string))
        object["log"] = .array(log.map(\.json))
        object["createdAt"] = .number(createdAt)
        object["updatedAt"] = .number(updatedAt)
        return .object(object)
    }

    // MARK: Storage

    public static let kvPrefix = "task/"

    public static func kvKey(id: String) -> String { "task/\(id.lowercased())" }

    func sealed(machineKey: Data) throws -> String {
        try AccountScopedBlob.seal(json, kind: .agentTask, machineKey: machineKey)
    }

    static func open(_ base64: String, machineKey: Data) -> AgentTask? {
        AccountScopedBlob.open(base64, kind: .agentTask, machineKey: machineKey).flatMap(AgentTask.init(json:))
    }

    /// A `GET /v1/kv?prefix=task/` response: the tasks that open with this key, with their versions.
    static func records(fromList response: JSONValue, machineKey: Data) -> [AgentTask] {
        (response["items"]?.arrayValue ?? []).compactMap { item in
            guard let key = item["key"]?.stringValue, key.hasPrefix(kvPrefix),
                  let value = item["value"]?.stringValue, !value.isEmpty,
                  var task = open(value, machineKey: machineKey), kvKey(id: task.id) == key else { return nil }
            task.version = item["version"]?.intValue ?? 0
            return task
        }
    }

    // MARK: Updates (`applyAgentTaskUpdate`)

    /// A change to a task. Optional fields that can be cleared use `.some(nil)`.
    public struct Update: Sendable, Equatable {
        public var title: String?
        public var description: String??
        public var assignee: Assignee?
        public var status: Status?
        public var startAt: Double??
        public var dueAt: Double??
        public var machineId: String??
        public var directory: String??
        public var source: Source??
        public var comment: String?
        /// The session that worked on it, linked once.
        public var threadSessionId: String?

        public init(title: String? = nil, description: String?? = nil, assignee: Assignee? = nil, status: Status? = nil,
                    startAt: Double?? = nil, dueAt: Double?? = nil, machineId: String?? = nil, directory: String?? = nil,
                    source: Source?? = nil, comment: String? = nil, threadSessionId: String? = nil) {
            self.title = title
            self.description = description
            self.assignee = assignee
            self.status = status
            self.startAt = startAt
            self.dueAt = dueAt
            self.machineId = machineId
            self.directory = directory
            self.source = source
            self.comment = comment
            self.threadSessionId = threadSessionId
        }

        /// Only what `edited` changed from `original`, so writing it on a newer copy keeps others' changes.
        public init(from original: AgentTask, to edited: AgentTask) {
            self.init()
            if edited.title != original.title { title = edited.title }
            if edited.description != original.description { description = .some(edited.description) }
            if edited.assignee != original.assignee { assignee = edited.assignee }
            if edited.status != original.status { status = edited.status }
            if edited.startAt != original.startAt { startAt = .some(edited.startAt) }
            if edited.dueAt != original.dueAt { dueAt = .some(edited.dueAt) }
            if edited.machineId != original.machineId { machineId = .some(edited.machineId) }
            if edited.directory != original.directory { directory = .some(edited.directory) }
            if edited.source != original.source { source = .some(edited.source) }
        }

        public var isEmpty: Bool { self == Update() }
    }

    /// The task after `update`, made by the user: a status change or a comment goes to the log.
    public func applying(_ update: Update, now: Double) -> AgentTask {
        var next = self
        next.updatedAt = now
        if let title = update.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { next.title = title }
        if let description = update.description { next.description = description }
        if let assignee = update.assignee { next.assignee = assignee }
        let statusChanged = update.status != nil && update.status != status
        if let status = update.status { next.status = status }
        if let startAt = update.startAt { next.startAt = startAt }
        if let dueAt = update.dueAt { next.dueAt = dueAt }
        if let machineId = update.machineId { next.machineId = machineId }
        if let directory = update.directory { next.directory = directory }
        if let source = update.source { next.source = source }
        if let thread = update.threadSessionId, !thread.isEmpty, !threads.contains(thread) { next.threads.append(thread) }
        let comment = update.comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        if (comment?.isEmpty == false) || statusChanged {
            next.log.append(LogEntry(at: now, by: ["kind": "user"], text: comment?.isEmpty == false ? comment : nil,
                                     status: statusChanged ? update.status : nil))
        }
        return next
    }

    // MARK: Filters

    public enum AssigneeFilter: Hashable, Sendable {
        case all, me
        case agent(String)
    }

    public enum StatusFilter: Hashable, Sendable {
        /// Everything not done.
        case open, all
        case only(Status)
    }

    /// The matching tasks, soonest due first (no due date last), then oldest first.
    public static func filter(_ tasks: [AgentTask], assignee: AssigneeFilter, status: StatusFilter) -> [AgentTask] {
        tasks.filter { task in
            switch assignee {
            case .all: break
            case .me: if task.assignee != .user { return false }
            case .agent(let id): if task.assignee.agentId != id { return false }
            }
            switch status {
            case .all: return true
            case .open: return task.status != .done
            case .only(let only): return task.status == only
            }
        }
        .sorted { a, b in
            let aDue = a.dueAt ?? .infinity, bDue = b.dueAt ?? .infinity
            return aDue != bDue ? aDue < bDue : a.createdAt < b.createdAt
        }
    }

    // MARK: Due date (`describeTaskDue`)

    public struct Due: Sendable, Equatable {
        public var text: String
        public var overdue: Bool
    }

    public func due(now: Double = ServerClock.nowMs()) -> Due? {
        guard let dueAt else { return nil }
        let span = Self.describeSpan(abs(dueAt - now))
        return dueAt < now ? Due(text: "overdue by \(span)", overdue: true) : Due(text: "due in \(span)", overdue: false)
    }

    private static func describeSpan(_ ms: Double) -> String {
        let hours = (ms / 3_600_000).rounded()
        if hours < 1 { return "\(max(1, Int((ms / 60_000).rounded()))) min" }
        return hours < 48 ? "\(Int(hours)) h" : "\(Int((hours / 24).rounded())) days"
    }

    // MARK: Assign to an agent

    /// The first message of the session an agent starts the task in: everything it needs to begin.
    public func assignmentMessage(agentName: String, timeZone: TimeZone = .current) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = timeZone
        format.dateFormat = "yyyy-MM-dd HH:mm"
        func date(_ ms: Double?) -> String? { ms.map { format.string(from: Date(timeIntervalSince1970: $0 / 1000)) } }

        var lines = ["\(agentName), this task is now yours: \(title)", "Task id: \(id)"]
        if let description, !description.isEmpty { lines += ["", "What was asked:", description] }
        if let source {
            let from = [source.label, source.url].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " — ")
            lines += ["", "Where it came from (\(source.kind)): \(from.isEmpty ? "no link" : from)"]
        }
        let dates = [date(startAt).map { "starts \($0)" }, date(dueAt).map { "due \($0)" }].compactMap { $0 }
        if !dates.isEmpty { lines += ["Dates: \(dates.joined(separator: ", "))"] }
        lines += ["", "Work on it here. Update it with tarea_actualizar (task id \(id)): progress comments, status changes, and in_review or done when you finish."]
        return lines.joined(separator: "\n")
    }
}

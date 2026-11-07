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
        /// One session: starting the task sends it a message there. `title` is a display hint.
        case session(id: String, title: String?)

        public static func agent(_ profile: AgentProfile) -> Assignee {
            .agent(id: profile.id, name: profile.name, emoji: profile.emoji)
        }

        public var agentId: String? {
            if case .agent(let id, _, _) = self { return id }
            return nil
        }

        public var sessionId: String? {
            if case .session(let id, _) = self { return id }
            return nil
        }

        /// The name shown; a session's own title (from the session list) is better when known.
        public var label: String {
            switch self {
            case .user: String(localized: "Me")
            // The name only: the emoji is kept in the task for the agent's identity, not shown.
            case .agent(_, let name, _): name ?? ""
            case .session(let id, let title): title?.isEmpty == false ? title! : id
            }
        }

        /// Groups: you, then agents, then sessions.
        var groupKey: String {
            switch self {
            case .user: ""
            case .agent(let id, _, _): "agent:\(id)"
            case .session(let id, _): "session:\(id)"
            }
        }

        var groupRank: Int {
            switch self {
            case .user: 0
            case .agent: 1
            case .session: 2
            }
        }

        init?(json: JSONValue?) {
            switch json?["kind"]?.stringValue {
            case "user": self = .user
            case "agent":
                guard let id = json?["agentId"]?.stringValue, !id.isEmpty else { return nil }
                self = .agent(id: id, name: json?["name"]?.stringValue, emoji: json?["emoji"]?.stringValue)
            case "session":
                guard let id = json?["sessionId"]?.stringValue, !id.isEmpty else { return nil }
                self = .session(id: id, title: json?["title"]?.stringValue)
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
            case .session(let id, let title):
                var object: [String: JSONValue] = ["kind": "session", "sessionId": .string(id)]
                if let title, !title.isEmpty { object["title"] = .string(title) }
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

    /// Repeats on these rules; kept as written in the task (unknown fields included) until edited here.
    public var recurrence: TaskRecurrence? {
        get { TaskRecurrence(json: extra["recurrence"]) }
        set { extra["recurrence"] = newValue?.json }
    }

    /// A pending one-time start; the daemon removes it once it started the task.
    public var scheduledStart: TaskScheduledStart? {
        get { TaskScheduledStart(json: extra["scheduledStartV1"]) }
        set { extra["scheduledStartV1"] = newValue?.json }
    }

    /// How every start of the task runs ("Start now", "Schedule…", each occurrence), for an agent or
    /// a session. YOLO when the task has none (new tasks, and those written before the field).
    /// Stored with the protocol's intent names (`read_only`, `default`, `auto`, `yolo`).
    public var permissionMode: PermissionMode {
        get {
            switch extra["permissionMode"]?.stringValue {
            case "read_only": .readOnly
            case "default": .default
            case "auto": .safeYolo
            default: .yolo
            }
        }
        set {
            let intent = switch newValue {
            case .readOnly: "read_only"
            case .default: "default"
            case .safeYolo: "auto"
            case .yolo: "yolo"
            }
            extra["permissionMode"] = .string(intent)
        }
    }

    /// When the user archived it (not going to do it): hidden by default, never deleted.
    public var archivedAt: Double? {
        get { extra["archivedAt"]?.doubleValue }
        set { extra["archivedAt"] = newValue.map(JSONValue.number) }
    }

    public var isArchived: Bool { archivedAt != nil }

    /// Still to do: not done and not archived (`isAgentTaskOpen`).
    public var isOpen: Bool { status != .done && !isArchived }

    /// Whether the list's circle completes it: an open task that doesn't repeat (a repeating one is
    /// archived or paused instead; its occurrences report their own results).
    public var completesFromList: Bool { isOpen && recurrence == nil }

    /// Each firing of a rule, oldest first, as the CLI wrote it. Read-only here: the stored copy is kept.
    public var occurrences: [TaskOccurrence] {
        extra["occurrences"]?.arrayValue?.compactMap(TaskOccurrence.init(json:)) ?? []
    }

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
    /// Closing a task that still repeats pauses its repetition, so its Automations stop firing on
    /// a closed task; the user resumes it from the app if they reopen it. Nil when nothing to pause.
    public func recurrenceToPause(closingWith update: Update) -> TaskRecurrence? {
        let closing = (update.status == .done && status != .done) || (update.archived == true && !isArchived)
        guard closing, var recurrence, !recurrence.paused else { return nil }
        recurrence.paused = true
        return recurrence
    }

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
        /// The whole recurrence (`.some(nil)` removes it).
        public var recurrence: TaskRecurrence??
        /// The session that worked on it, linked once.
        public var threadSessionId: String?
        /// The pending one-time start (`.some(nil)` removes it).
        public var scheduledStart: TaskScheduledStart??
        public var permissionMode: PermissionMode?
        /// Archives (true) or restores (false) it.
        public var archived: Bool?

        public init(title: String? = nil, description: String?? = nil, assignee: Assignee? = nil, status: Status? = nil,
                    startAt: Double?? = nil, dueAt: Double?? = nil, machineId: String?? = nil, directory: String?? = nil,
                    source: Source?? = nil, comment: String? = nil, recurrence: TaskRecurrence?? = nil, threadSessionId: String? = nil,
                    scheduledStart: TaskScheduledStart?? = nil, permissionMode: PermissionMode? = nil, archived: Bool? = nil) {
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
            self.recurrence = recurrence
            self.threadSessionId = threadSessionId
            self.scheduledStart = scheduledStart
            self.permissionMode = permissionMode
            self.archived = archived
        }

        /// "Archive" / "Unarchive".
        public static func archiving(_ archived: Bool) -> Update { Update(archived: archived) }

        /// "Assign to…": only who it's for; the status stays and nothing starts.
        public static func assigning(_ assignee: Assignee) -> Update { Update(assignee: assignee) }

        /// "Start Now" worked: the session that took it is linked and it is in progress.
        public static func started(sessionId: String) -> Update { Update(status: .inProgress, threadSessionId: sessionId) }

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
            if edited.recurrence != original.recurrence { recurrence = .some(edited.recurrence) }
            if edited.scheduledStart != original.scheduledStart { scheduledStart = .some(edited.scheduledStart) }
            if edited.permissionMode != original.permissionMode { permissionMode = edited.permissionMode }
            if edited.isArchived != original.isArchived { archived = edited.isArchived }
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
        if let recurrence = update.recurrence { next.recurrence = recurrence }
        if let scheduledStart = update.scheduledStart { next.scheduledStart = scheduledStart }
        if let permissionMode = update.permissionMode { next.permissionMode = permissionMode }
        if update.archived == true, !isArchived { next.archivedAt = now }
        if update.archived == false { next.archivedAt = nil }
        if let thread = update.threadSessionId, !thread.isEmpty, !threads.contains(thread) { next.threads.append(thread) }
        let comment = update.comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        if (comment?.isEmpty == false) || statusChanged {
            next.log.append(LogEntry(at: now, by: ["kind": "user"], text: comment?.isEmpty == false ? comment : nil,
                                     status: statusChanged ? update.status : nil))
        }
        return next
    }

    /// `update`, plus cancelling a pending start when it hands the task to someone else: the start's
    /// Automation was made for the previous assignee's agent and machine.
    public func scheduleAware(_ update: Update) -> Update {
        guard let assignee = update.assignee, assignee != self.assignee, scheduledStart != nil, update.scheduledStart == nil else { return update }
        var next = update
        next.scheduledStart = .some(nil)
        return next
    }

    // MARK: Sessions and sections (tasks belong to the account; some are linked to sessions)

    /// Why a session is linked to a task.
    public enum SessionLink: String, Sendable, Equatable {
        /// The task came from it (`source.sessionId`).
        case source
        /// It worked on the task (`threads`).
        case worked
        /// It worked one of the task's repeating occurrences.
        case occurrence
        /// The task is assigned to it.
        case assigned
    }

    public struct LinkedSession: Sendable, Equatable, Identifiable {
        public let sessionId: String
        public let reasons: [SessionLink]
        public var id: String { sessionId }
    }

    /// Every session linked to this task, in the order they appeared: where it came from first.
    public var linkedSessions: [LinkedSession] {
        var order: [String] = []
        var reasons: [String: [SessionLink]] = [:]
        func add(_ sessionId: String?, _ reason: SessionLink) {
            guard let sessionId, !sessionId.isEmpty else { return }
            if reasons[sessionId] == nil { order.append(sessionId) }
            if reasons[sessionId]?.contains(reason) != true { reasons[sessionId, default: []].append(reason) }
        }
        add(assignee.sessionId, .assigned)
        add(source?.sessionId, .source)
        for thread in threads { add(thread, .worked) }
        for occurrence in occurrences { add(occurrence.sessionId, .occurrence) }
        return order.map { LinkedSession(sessionId: $0, reasons: reasons[$0] ?? []) }
    }

    public func isLinked(to sessionId: String) -> Bool {
        linkedSessions.contains { $0.sessionId == sessionId }
    }

    /// What the Tasks list shows: every task of the account, or only those linked to the open session.
    public enum Scope: Hashable, Sendable { case all, thisSession }

    public struct Section: Sendable, Equatable, Identifiable {
        public enum Kind: Hashable, Sendable {
            case linkedToOpenSession
            case assignee(Assignee)
        }
        public let kind: Kind
        public let tasks: [AgentTask]
        public var id: Kind { kind }
    }

    /// "All": the tasks linked to the open session first (when there are any), then every task
    /// grouped by who it's for (you first, then agents by name). "This session": only the linked ones.
    public static func sections(_ tasks: [AgentTask], scope: Scope, openSessionId: String?, status: StatusFilter,
                                showCompleted: Bool = false, showArchived: Bool = false) -> [Section] {
        let visible = filter(tasks, assignee: .all, status: status, showCompleted: showCompleted, showArchived: showArchived)
        let linked = openSessionId.map { id in visible.filter { $0.isLinked(to: id) } } ?? []
        switch scope {
        case .thisSession:
            return linked.isEmpty ? [] : [Section(kind: .linkedToOpenSession, tasks: linked)]
        case .all:
            var groups: [String: (assignee: Assignee, tasks: [AgentTask])] = [:]
            for task in visible {
                groups[task.assignee.groupKey, default: (task.assignee, [])].tasks.append(task)
            }
            let ordered = groups.values.sorted { a, b in
                if a.assignee.groupRank != b.assignee.groupRank { return a.assignee.groupRank < b.assignee.groupRank }
                return a.assignee.label.localizedStandardCompare(b.assignee.label) == .orderedAscending
            }
            return (linked.isEmpty ? [] : [Section(kind: .linkedToOpenSession, tasks: linked)])
                + ordered.map { Section(kind: .assignee($0.assignee), tasks: $0.tasks) }
        }
    }

    // MARK: Filters

    public enum AssigneeFilter: Hashable, Sendable {
        case all, me
        case agent(String)
        case session(String)
    }

    public enum StatusFilter: Hashable, Sendable {
        /// Everything not done.
        case open, all
        case only(Status)
    }

    /// The matching tasks, soonest due first (no due date last), then oldest first. Archived tasks
    /// only with `showArchived`; "Open" adds the completed ones with `showCompleted`.
    public static func filter(_ tasks: [AgentTask], assignee: AssigneeFilter, status: StatusFilter,
                              showCompleted: Bool = false, showArchived: Bool = false) -> [AgentTask] {
        tasks.filter { task in
            if task.isArchived, !showArchived { return false }
            switch assignee {
            case .all: break
            case .me: if task.assignee != .user { return false }
            case .agent(let id): if task.assignee.agentId != id { return false }
            case .session(let id): if task.assignee.sessionId != id { return false }
            }
            switch status {
            case .all: return true
            case .open: return task.status != .done || showCompleted
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

    /// The message that starts the task: the first one of the session an agent starts it in, or the
    /// one sent to the session it's assigned to (no agent name). Everything it needs to begin.
    public func assignmentMessage(agentName: String?, timeZone: TimeZone = .current) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = timeZone
        format.dateFormat = "yyyy-MM-dd HH:mm"
        func date(_ ms: Double?) -> String? { ms.map { format.string(from: Date(timeIntervalSince1970: $0 / 1000)) } }

        let opening = agentName.map { "\($0), this task is now yours: \(title)" } ?? "This task is now yours: \(title)"
        var lines = [opening, "Task id: \(id)"]
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

import Foundation

/// Searching the account's tasks with `SearchIndex`: every field a person might remember (title,
/// description, comments, source and its link, who it's for, status, folder and machine, the
/// sessions linked to it, dates as text). The search ignores the list's filter; completed and
/// archived tasks come after the open ones.
public final class TaskSearch {
    /// Names the task itself doesn't hold, looked up where the app keeps them.
    public struct Context {
        public var assigneeName: (AgentTask.Assignee) -> String
        public var sessionTitle: (String) -> String?
        public var machineName: (String) -> String?
        public var timeZone: TimeZone

        public init(assigneeName: @escaping (AgentTask.Assignee) -> String = { $0.label },
                    sessionTitle: @escaping (String) -> String? = { _ in nil },
                    machineName: @escaping (String) -> String? = { _ in nil },
                    timeZone: TimeZone = .current) {
            self.assigneeName = assigneeName
            self.sessionTitle = sessionTitle
            self.machineName = machineName
            self.timeZone = timeZone
        }
    }

    /// Field tags, so a result can say where it matched.
    public enum Field: String, Sendable {
        case title, description, comment, source, assignee, status, place, session, date

        public var label: String {
            switch self {
            case .title: String(localized: "Title")
            case .description: String(localized: "Description")
            case .comment: String(localized: "Comment")
            case .source: String(localized: "Source")
            case .assignee: String(localized: "For")
            case .status: String(localized: "Status")
            case .place: String(localized: "Folder")
            case .session: String(localized: "Session")
            case .date: String(localized: "Date")
            }
        }
    }

    public struct Result: Identifiable, Sendable {
        public let task: AgentTask
        /// Matched words of the title, to highlight.
        public let titleHighlights: [Range<String.Index>]
        /// Where it matched when not in the title: the field and a piece of it.
        public let snippet: (field: Field, snippet: SearchSnippet)?
        /// Done or archived: listed after the open tasks and marked so.
        public var isClosed: Bool { !task.isOpen }
        public var id: String { task.id }
    }

    private let index = SearchIndex<String>()
    /// What each indexed task was built from, so an unchanged task isn't indexed again.
    private var fingerprints: [String: String] = [:]

    public init() {}

    /// Brings the index in step with `tasks`: new and changed tasks are indexed, gone ones removed.
    public func sync(_ tasks: [AgentTask], context: Context) {
        var seen = Set<String>()
        for task in tasks {
            seen.insert(task.id)
            let print = fingerprint(task, context: context)
            guard fingerprints[task.id] != print else { continue }
            index.upsert(task.id, fields: Self.fields(task, context: context))
            fingerprints[task.id] = print
        }
        for id in fingerprints.keys where !seen.contains(id) {
            index.remove(id)
            fingerprints[id] = nil
        }
    }

    /// The tasks matching `query`: open ones first, then completed and archived; within each, by
    /// rank, and the nearest due date breaks ties.
    public func search(_ query: String, in tasks: [AgentTask]) -> [Result] {
        let byId = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let hits = index.search(query) { a, b in
            (byId[a]?.dueAt ?? .infinity) < (byId[b]?.dueAt ?? .infinity)
        }
        var open: [Result] = [], closed: [Result] = []
        for hit in hits {
            guard let task = byId[hit.id], let fields = index.fields(of: hit.id) else { continue }
            let title = hit.matches.filter { fields[$0.field].tag == Field.title.rawValue }.map(\.range)
            var snippet: (Field, SearchSnippet)?
            if title.isEmpty, let first = hit.matches.min(by: { fields[$0.field].rank < fields[$1.field].rank }) {
                let field = fields[first.field]
                let ranges = hit.matches.filter { $0.field == first.field }.map(\.range)
                snippet = (Field(rawValue: field.tag) ?? .description, SearchSnippet(text: field.text, matches: ranges))
            }
            let result = Result(task: task, titleHighlights: title, snippet: snippet)
            if result.isClosed { closed.append(result) } else { open.append(result) }
        }
        return open + closed
    }

    // MARK: Fields

    private func fingerprint(_ task: AgentTask, context: Context) -> String {
        let names = [context.assigneeName(task.assignee), task.machineId.flatMap(context.machineName) ?? ""]
            + task.linkedSessions.map { context.sessionTitle($0.sessionId) ?? "" }
        return "\(task.version)|\(task.updatedAt)|\(task.status.rawValue)|\(task.archivedAt ?? 0)|" + names.joined(separator: "|")
    }

    static func fields(_ task: AgentTask, context: Context) -> [SearchField] {
        var fields = [SearchField(rank: 0, tag: Field.title.rawValue, text: task.title)]
        func add(_ rank: Int, _ field: Field, _ text: String?) {
            guard let text, !text.isEmpty else { return }
            fields.append(SearchField(rank: rank, tag: field.rawValue, text: text))
        }
        add(1, .description, task.description)
        for entry in task.log { add(2, .comment, entry.text) }
        add(3, .source, task.source?.label)
        add(3, .source, task.source?.url)
        add(4, .assignee, context.assigneeName(task.assignee))
        add(4, .status, task.isArchived ? "\(task.status.label) · Archived" : task.status.label)
        add(4, .place, task.directory)
        add(4, .place, task.machineId.flatMap(context.machineName))
        for link in task.linkedSessions { add(4, .session, context.sessionTitle(link.sessionId)) }
        for at in [task.dueAt, task.startAt].compactMap({ $0 }) { add(4, .date, dateText(at, timeZone: context.timeZone)) }
        return fields
    }

    /// A date as people type it: "Saturday 12 September 2026", "sábado 12 septiembre 2026", "2026-09-12".
    static func dateText(_ ms: Double, timeZone: TimeZone) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        let words = ["en_US", "es_MX"].map { identifier in
            date.formatted(Date.FormatStyle(locale: Locale(identifier: identifier), timeZone: timeZone)
                .weekday(.wide).day().month(.wide).year())
        }
        let iso = date.formatted(Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day())
        return (words + [iso]).joined(separator: " · ")
    }
}

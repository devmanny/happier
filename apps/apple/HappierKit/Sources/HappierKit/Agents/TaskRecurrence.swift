import Foundation

/// A task that repeats (`packages/protocol/src/tasks/agentTaskRecurrence.ts`). Each rule is one
/// Automation on the server (cron in the recurrence's time zone, assigned to the task's machine), so
/// the existing Automations engine is the only scheduler; the CLI daemon that claims a run works the
/// occurrence and records it in the task's `occurrences`.
public struct TaskRecurrence: Sendable, Equatable {
    public enum Continuity: String, Sendable, CaseIterable, Identifiable {
        case sameThread = "same_thread"
        case newThread = "new_thread"

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .sameThread: String(localized: "Continue the same thread")
            case .newThread: String(localized: "Open a new thread each time")
            }
        }
    }

    public struct Rule: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable {
            /// 0 = Sunday … 6 = Saturday, as cron counts them.
            case weekly(Set<Int>)
            case everyNDays(Int, anchorDate: String)
            case monthly(Int)
        }

        public var id: String
        public var kind: Kind
        public var hour: Int
        public var minute: Int
        /// The server Automation that fires this rule, once created.
        public var automationId: String?

        public init(id: String = UUID().uuidString.lowercased(), kind: Kind, hour: Int, minute: Int, automationId: String? = nil) {
            self.id = id
            self.kind = kind
            self.hour = hour
            self.minute = minute
            self.automationId = automationId
        }

        /// `recurrenceRuleCron`: "Every N days" fires daily; the daemon decides the occurrence day.
        public var cron: String {
            switch kind {
            case .weekly(let days): "\(minute) \(hour) * * \(days.sorted().map(String.init).joined(separator: ","))"
            case .monthly(let day): "\(minute) \(hour) \(day) * *"
            case .everyNDays: "\(minute) \(hour) * * *"
            }
        }

        public var time: String { String(format: "%02d:%02d", hour, minute) }

        /// "Mon–Fri 09:00", "Every 3 days from 2026-11-07 at 07:00", "Day 15 at 08:30".
        public var summary: String {
            switch kind {
            case .weekly(let days): "\(Self.describe(days)) \(time)"
            case .everyNDays(let n, let anchor): n == 1 ? "Every day at \(time)" : "Every \(n) days from \(anchor) at \(time)"
            case .monthly(let day): "Day \(day) of the month at \(time)"
            }
        }

        static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

        static func describe(_ days: Set<Int>) -> String {
            if days == [1, 2, 3, 4, 5] { return "Mon–Fri" }
            if days == [0, 6] { return "Sat–Sun" }
            if days.count == 7 { return "Every day" }
            // Monday first, as the week reads.
            return days.sorted { ($0 + 6) % 7 < ($1 + 6) % 7 }.map { weekdayNames[$0] }.joined(separator: ", ")
        }

        init?(json: JSONValue) {
            guard let id = json["id"]?.stringValue, !id.isEmpty, let time = json["time"]?.stringValue else { return nil }
            let parts = time.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
            switch json["kind"]?.stringValue {
            case "weekly":
                let days = Set(json["weekdays"]?.arrayValue?.compactMap(\.intValue) ?? [])
                guard !days.isEmpty, days.allSatisfy({ (0...6).contains($0) }) else { return nil }
                kind = .weekly(days)
            case "every_n_days":
                guard let n = json["everyDays"]?.intValue, n >= 1, let anchor = json["anchorDate"]?.stringValue else { return nil }
                kind = .everyNDays(n, anchorDate: anchor)
            case "monthly":
                guard let day = json["dayOfMonth"]?.intValue, (1...31).contains(day) else { return nil }
                kind = .monthly(day)
            default:
                return nil
            }
            self.id = id
            self.hour = parts[0]
            self.minute = parts[1]
            self.automationId = json["automationId"]?.stringValue
        }

        var json: JSONValue {
            var object: [String: JSONValue] = ["id": .string(id), "time": .string(time)]
            switch kind {
            case .weekly(let days):
                object["kind"] = "weekly"
                object["weekdays"] = .array(days.sorted().map { .number(Double($0)) })
            case .everyNDays(let n, let anchor):
                object["kind"] = "every_n_days"
                object["everyDays"] = .number(Double(n))
                object["anchorDate"] = .string(anchor)
            case .monthly(let day):
                object["kind"] = "monthly"
                object["dayOfMonth"] = .number(Double(day))
            }
            if let automationId { object["automationId"] = .string(automationId) }
            return .object(object)
        }
    }

    public var timezone: String
    public var continuity: Continuity
    public var paused: Bool
    public var rules: [Rule]

    public init(timezone: String = TimeZone.current.identifier, continuity: Continuity = .newThread, paused: Bool = false, rules: [Rule] = []) {
        self.timezone = timezone
        self.continuity = continuity
        self.paused = paused
        self.rules = rules
    }

    init?(json: JSONValue?) {
        guard let json, json["v"]?.intValue == 1, let timezone = json["timezone"]?.stringValue,
              let continuity = json["continuity"]?.stringValue.flatMap(Continuity.init(rawValue:)) else { return nil }
        let rules = json["rules"]?.arrayValue?.compactMap(Rule.init(json:)) ?? []
        guard !rules.isEmpty else { return nil }
        self.init(timezone: timezone, continuity: continuity, paused: json["paused"]?.boolValue ?? false, rules: rules)
    }

    var json: JSONValue {
        ["v": 1, "timezone": .string(timezone), "continuity": .string(continuity.rawValue), "paused": .bool(paused),
         "rules": .array(rules.map(\.json))]
    }

    // MARK: Next run

    /// When the next occurrence fires after `date`, across every rule; nil when paused or empty.
    /// Walks calendar days in the recurrence's time zone, so the wall-clock time holds across DST.
    public func nextRun(after date: Date = .now) -> Date? {
        guard !paused else { return nil }
        return rules.compactMap { nextRun(of: $0, after: date) }.min()
    }

    public func nextRun(of rule: Rule, after date: Date) -> Date? {
        guard let zone = TimeZone(identifier: timezone) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = calendar.startOfDay(for: date)
        var horizon = 400
        if case .everyNDays(let n, _) = rule.kind { horizon = max(horizon, n + 400) }
        for offset in 0...horizon {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            guard matches(rule, parts: parts, calendar: calendar, zone: zone) else { continue }
            var at = DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: rule.hour, minute: rule.minute)
            at.timeZone = zone
            if let fire = calendar.date(from: at), fire > date { return fire }
        }
        return nil
    }

    private func matches(_ rule: Rule, parts: DateComponents, calendar: Calendar, zone: TimeZone) -> Bool {
        switch rule.kind {
        case .weekly(let days):
            return days.contains((parts.weekday ?? 1) - 1)
        case .monthly(let day):
            return parts.day == day
        case .everyNDays(let n, let anchor):
            let pieces = anchor.split(separator: "-").compactMap { Int($0) }
            guard pieces.count == 3, n >= 1 else { return false }
            var anchorParts = DateComponents(year: pieces[0], month: pieces[1], day: pieces[2])
            anchorParts.timeZone = zone
            var dayParts = DateComponents(year: parts.year, month: parts.month, day: parts.day)
            dayParts.timeZone = zone
            guard let anchorDay = calendar.date(from: anchorParts), let thisDay = calendar.date(from: dayParts),
                  let days = calendar.dateComponents([.day], from: anchorDay, to: thisDay).day else { return false }
            return days >= 0 && days % n == 0
        }
    }

    // MARK: Automation template

    /// The Automation's template: only what the engine's schema requires plus the task and rule. The
    /// daemon builds the occurrence from the current task and agent when it fires, so later edits apply.
    public static func automationTemplateCiphertext(taskId: String, ruleId: String, directory: String, providerId: String,
                                                    machineKey: Data) throws -> String {
        let payload: JSONValue = [
            "directory": .string(directory), "agent": .string(providerId), "prompt": "Recurring task",
            "agentTaskV1": ["taskId": .string(taskId), "ruleId": .string(ruleId)],
        ]
        let envelope: JSONValue = [
            "kind": "happier_automation_template_encrypted_v1",
            "payloadCiphertext": .string(try AccountScopedBlob.seal(payload, kind: .automationTemplatePayload, machineKey: machineKey)),
        ]
        return String(decoding: try envelope.encoded(), as: UTF8.self)
    }

    // MARK: Terms

    /// Anthropic's Consumer Terms (section 3.7) ask for an API key for automated access, so repeating
    /// work on a Claude agent warns (it never blocks). Other providers don't.
    public static func needsAutomatedAccessWarning(providerId: String?) -> Bool {
        providerId == "claude"
    }

    /// The Automations routes answered 404: this relay doesn't offer them.
    public struct AutomationsUnavailable: Error, LocalizedError {
        public var errorDescription: String? {
            String(localized: "Repeating tasks need Automations, which this relay doesn't offer.")
        }
    }
}

/// One firing of a rule in a task's history, written by the CLI.
public struct TaskOccurrence: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable {
        case running, completed, skipped, failed, interrupted

        public var label: String {
            switch self {
            case .running: String(localized: "Running")
            case .completed: String(localized: "Completed")
            case .skipped: String(localized: "Skipped")
            case .failed: String(localized: "Failed")
            case .interrupted: String(localized: "Interrupted")
            }
        }
    }

    public var id: String
    public var ruleId: String?
    public var dueAt: Double?
    public var startedAt: Double
    public var finishedAt: Double?
    public var sessionId: String?
    public var status: Status
    public var note: String?

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, let startedAt = json["startedAt"]?.doubleValue,
              let status = json["status"]?.stringValue.flatMap(Status.init(rawValue:)) else { return nil }
        self.id = id
        self.ruleId = json["ruleId"]?.stringValue
        self.dueAt = json["dueAt"]?.doubleValue
        self.startedAt = startedAt
        self.finishedAt = json["finishedAt"]?.doubleValue
        self.sessionId = json["sessionId"]?.stringValue
        self.status = status
        self.note = json["note"]?.stringValue
    }
}

// MARK: - Automations API (`apps/server/sources/app/api/routes/automations`)

extension HappierAPI {
    private static func automationBody(rule: TaskRecurrence.Rule, timezone: String, machineId: String, templateCiphertext: String) -> [String: JSONValue] {
        [
            "schedule": ["kind": "cron", "scheduleExpr": .string(rule.cron), "timezone": .string(timezone)],
            "templateCiphertext": .string(templateCiphertext),
            "assignments": [["machineId": .string(machineId)]],
        ]
    }

    /// Runs `call`, turning the routes' absence (404 without `automation_not_found`) into `AutomationsUnavailable`.
    func automations<T>(_ call: () async throws -> T) async throws -> T {
        do {
            return try await call()
        } catch let error as HTTPClient.ServerError where error.status == 404 && error.body?["error"]?.stringValue != "automation_not_found" {
            throw TaskRecurrence.AutomationsUnavailable()
        }
    }

    /// Creates the Automation that fires `rule`; returns its id.
    func createTaskAutomation(taskId: String, rule: TaskRecurrence.Rule, timezone: String, enabled: Bool, machineId: String,
                              templateCiphertext: String) async throws -> String {
        var body = Self.automationBody(rule: rule, timezone: timezone, machineId: machineId, templateCiphertext: templateCiphertext)
        body["name"] = .string("task \(taskId) rule \(rule.id)")
        body["enabled"] = .bool(enabled)
        body["targetType"] = "new_session"
        let response = try await automations { try await http.post("/v2/automations", .object(body)) }
        guard let id = response["id"]?.stringValue else { throw HTTPClient.ServerError(status: 200, path: "/v2/automations", body: response) }
        return id
    }

    func updateTaskAutomation(id: String, rule: TaskRecurrence.Rule, timezone: String, machineId: String, templateCiphertext: String) async throws {
        let body = Self.automationBody(rule: rule, timezone: timezone, machineId: machineId, templateCiphertext: templateCiphertext)
        _ = try await automations { try await http.patch("/v2/automations/\(id)", .object(body)) }
    }

    func setTaskAutomation(id: String, paused: Bool) async throws {
        _ = try await automations { try await http.post("/v2/automations/\(id)/\(paused ? "pause" : "resume")") }
    }

    func runTaskAutomationNow(id: String) async throws {
        _ = try await automations { try await http.post("/v2/automations/\(id)/run-now") }
    }

    /// Deletes the Automation; one already gone is fine.
    func deleteTaskAutomation(id: String) async throws {
        do {
            _ = try await automations { try await http.delete("/v2/automations/\(id)") }
        } catch let error as HTTPClient.ServerError where error.status == 404 {
            return
        }
    }
}

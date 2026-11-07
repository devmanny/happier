import Foundation

/// A one-time start ("Schedule…" on a task assigned to an agent or a session), as
/// `TaskScheduledStartV1Schema` in `packages/protocol/src/tasks/agentTaskRecurrence.ts` describes it:
/// one Automation whose cron names that minute, day and month in the user's time zone. The daemon
/// starts the task, clears this from the task and deletes the Automation, so a start is within a year.
public struct TaskScheduledStart: Sendable, Equatable {
    /// When it starts, in ms.
    public var at: Double
    public var timezone: String
    /// The server Automation that fires it, once created.
    public var automationId: String?

    public init(at: Double, timezone: String = TimeZone.current.identifier, automationId: String? = nil) {
        self.at = at
        self.timezone = timezone
        self.automationId = automationId
    }

    public var date: Date { Date(timeIntervalSince1970: at / 1000) }

    /// `scheduledStartCron`; nil when the time zone is unknown.
    public var cron: String? { Self.cron(at: date, timezone: timezone) }

    /// `scheduledStartCron`: "M H D Mo *" from `at`'s wall clock in `timezone`.
    public static func cron(at: Date, timezone: String) -> String? {
        guard let zone = TimeZone(identifier: timezone) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.minute, .hour, .day, .month], from: at)
        guard let minute = parts.minute, let hour = parts.hour, let day = parts.day, let month = parts.month else { return nil }
        return "\(minute) \(hour) \(day) \(month) *"
    }

    init?(json: JSONValue?) {
        guard let json, let at = json["at"]?.doubleValue, let timezone = json["timezone"]?.stringValue, !timezone.isEmpty else { return nil }
        self.init(at: at, timezone: timezone, automationId: json["automationId"]?.stringValue)
    }

    var json: JSONValue {
        var object: [String: JSONValue] = ["at": .number(at), "timezone": .string(timezone)]
        if let automationId { object["automationId"] = .string(automationId) }
        return .object(object)
    }

    /// The Automation's template: only what the engine's schema requires plus the task, so the daemon
    /// builds the start from the current task when it fires.
    public static func automationTemplateCiphertext(taskId: String, directory: String, providerId: String,
                                                    machineKey: Data) throws -> String {
        let payload: JSONValue = [
            "directory": .string(directory), "agent": .string(providerId), "prompt": "Scheduled task",
            "agentTaskV1": ["taskId": .string(taskId), "kind": "scheduled_start"],
        ]
        let envelope: JSONValue = [
            "kind": "happier_automation_template_encrypted_v1",
            "payloadCiphertext": .string(try AccountScopedBlob.seal(payload, kind: .automationTemplatePayload, machineKey: machineKey)),
        ]
        return String(decoding: try envelope.encoded(), as: UTF8.self)
    }

    public struct UnknownTimeZone: Error, LocalizedError {
        public let identifier: String
        public var errorDescription: String? { String(localized: "Unknown time zone \(identifier).") }
    }

    /// The latest start the picker offers: the cron repeats yearly, so a start is within a year.
    public static func latest(from now: Date = .now) -> Date {
        Calendar(identifier: .gregorian).date(byAdding: .year, value: 1, to: now) ?? now.addingTimeInterval(365 * 86_400)
    }
}

// MARK: - Automations API

extension HappierAPI {
    private static func cronSchedule(_ start: TaskScheduledStart) throws -> JSONValue {
        guard let cron = start.cron else {
            throw TaskScheduledStart.UnknownTimeZone(identifier: start.timezone)
        }
        return ["kind": "cron", "scheduleExpr": .string(cron), "timezone": .string(start.timezone)]
    }

    /// Creates the Automation that starts the task once; returns its id. The name is opaque.
    func createScheduledStartAutomation(taskId: String, start: TaskScheduledStart, machineId: String,
                                        templateCiphertext: String) async throws -> String {
        let body: JSONValue = [
            "name": .string("task \(taskId) start"), "enabled": true, "targetType": "new_session",
            "schedule": try Self.cronSchedule(start),
            "templateCiphertext": .string(templateCiphertext),
            "assignments": [["machineId": .string(machineId)]],
        ]
        let response = try await automations { try await http.post("/v2/automations", body) }
        guard let id = response["id"]?.stringValue else { throw HTTPClient.ServerError(status: 200, path: "/v2/automations", body: response) }
        return id
    }

    /// Moves the start to another time.
    func rescheduleStartAutomation(id: String, start: TaskScheduledStart) async throws {
        let body: JSONValue = ["schedule": try Self.cronSchedule(start)]
        _ = try await automations { try await http.patch("/v2/automations/\(id)", body) }
    }

    /// Runs the Automation on another machine.
    func moveTaskAutomation(id: String, machineId: String) async throws {
        let body: JSONValue = ["assignments": [["machineId": .string(machineId)]]]
        _ = try await automations { try await http.patch("/v2/automations/\(id)", body) }
    }
}

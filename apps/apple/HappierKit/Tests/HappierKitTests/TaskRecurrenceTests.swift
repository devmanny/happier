import Foundation
import Testing
@testable import HappierKit

/// Recurring tasks (`packages/protocol/src/tasks/agentTaskRecurrence.ts`): rules, their cron on the
/// Automations engine, the next run shown in the app, and the history the CLI writes.
@Suite struct TaskRecurrenceTests {
    static let weekdays9 = TaskRecurrence.Rule(id: "r1", kind: .weekly([1, 2, 3, 4, 5]), hour: 9, minute: 0)
    static let weekend16 = TaskRecurrence.Rule(id: "r2", kind: .weekly([6, 0]), hour: 16, minute: 0)

    private static func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    @Test func eachRuleMirrorsTheProtocolCron() {
        #expect(Self.weekdays9.cron == "0 9 * * 1,2,3,4,5")
        #expect(Self.weekend16.cron == "0 16 * * 0,6")
        #expect(TaskRecurrence.Rule(id: "r3", kind: .monthly(15), hour: 8, minute: 30).cron == "30 8 15 * *")
        #expect(TaskRecurrence.Rule(id: "r4", kind: .everyNDays(3, anchorDate: "2026-11-07"), hour: 7, minute: 5).cron == "5 7 * * *")
    }

    @Test func nextRunAcrossWeekdayAndWeekendRules() {
        let recurrence = TaskRecurrence(timezone: "America/Mexico_City", rules: [Self.weekdays9, Self.weekend16])
        // Friday 2026-11-06 10:00 in Mexico City (UTC-6): the weekday run already passed; next is Saturday 16:00.
        #expect(recurrence.nextRun(after: Self.date("2026-11-06T16:00:00Z")) == Self.date("2026-11-07T22:00:00Z"))
        // Sunday evening: next is Monday 9:00.
        #expect(recurrence.nextRun(after: Self.date("2026-11-08T23:00:00Z")) == Self.date("2026-11-09T15:00:00Z"))
        var paused = recurrence
        paused.paused = true
        #expect(paused.nextRun(after: Self.date("2026-11-06T16:00:00Z")) == nil)
    }

    @Test func monthlySkipsMonthsWithoutThatDay() {
        let recurrence = TaskRecurrence(timezone: "UTC", rules: [.init(id: "m", kind: .monthly(31), hour: 8, minute: 0)])
        // November has 30 days: the next 31st is in December.
        #expect(recurrence.nextRun(after: Self.date("2026-11-01T00:00:00Z")) == Self.date("2026-12-31T08:00:00Z"))
    }

    @Test func everyNDaysCountsFromItsAnchorInTheTimeZone() {
        let recurrence = TaskRecurrence(timezone: "America/Mexico_City",
                                        rules: [.init(id: "n", kind: .everyNDays(3, anchorDate: "2026-11-07"), hour: 7, minute: 0)])
        // 7:00 on the 7th already passed; the next is the 10th (3 days later), not the 8th.
        #expect(recurrence.nextRun(after: Self.date("2026-11-07T14:00:00Z")) == Self.date("2026-11-10T13:00:00Z"))
        // Before the anchor: the anchor itself.
        #expect(recurrence.nextRun(after: Self.date("2026-11-01T00:00:00Z")) == Self.date("2026-11-07T13:00:00Z"))
    }

    @Test func nextRunKeepsTheWallClockTimeAcrossDaylightSavingChanges() {
        let recurrence = TaskRecurrence(timezone: "America/New_York", rules: [.init(id: "d", kind: .weekly([0, 1]), hour: 9, minute: 0)])
        // DST starts Sunday 2026-03-08: 9:00 EDT is 13:00Z; the Sunday before (EST) it was 14:00Z.
        #expect(recurrence.nextRun(after: Self.date("2026-03-01T00:00:00Z")) == Self.date("2026-03-01T14:00:00Z"))
        #expect(recurrence.nextRun(after: Self.date("2026-03-07T00:00:00Z")) == Self.date("2026-03-08T13:00:00Z"))
    }

    @Test func recurrenceAndHistoryRoundTripAndSurviveEdits() throws {
        let json: JSONValue = [
            "v": 1, "id": "t1", "title": "Revisión diaria", "status": "todo", "assignee": ["kind": "agent", "agentId": "a"],
            "threads": [], "log": [], "createdAt": 1, "updatedAt": 1, "notifiedV1": ["dueSoonAt": 3],
            "recurrence": ["v": 1, "timezone": "America/Mexico_City", "continuity": "same_thread", "paused": false, "rules": [
                ["id": "r1", "kind": "weekly", "weekdays": [1, 2, 3, 4, 5], "time": "09:00", "automationId": "auto1"],
                ["id": "r2", "kind": "every_n_days", "everyDays": 2, "anchorDate": "2026-11-07", "time": "07:30"],
                ["id": "r3", "kind": "monthly", "dayOfMonth": 15, "time": "18:05"],
            ]],
            "occurrences": [["id": "run1", "ruleId": "r1", "startedAt": 10, "finishedAt": 20, "sessionId": "s1", "status": "completed", "note": "ok"]],
        ]
        let task = try #require(AgentTask(json: json))
        let recurrence = try #require(task.recurrence)
        #expect(recurrence.continuity == .sameThread)
        #expect(recurrence.rules.map(\.cron) == ["0 9 * * 1,2,3,4,5", "30 7 * * *", "5 18 15 * *"])
        #expect(recurrence.rules.first?.automationId == "auto1")
        #expect(task.occurrences.map(\.status) == [.completed])
        #expect(task.occurrences.first?.sessionId == "s1")

        let edited = task.applying(AgentTask.Update(title: "Revisión"), now: 50)
        #expect(edited.json["occurrences"] == json["occurrences"])
        #expect(edited.json["recurrence"] == json["recurrence"])
        #expect(edited.json["notifiedV1"] == json["notifiedV1"])

        var changed = recurrence
        changed.paused = true
        let paused = task.applying(AgentTask.Update(recurrence: .some(changed)), now: 60)
        #expect(paused.recurrence?.paused == true)
        #expect(task.applying(AgentTask.Update(recurrence: .some(nil)), now: 61).json["recurrence"] == nil)
    }

    @Test func automationTemplateCarriesOnlyTheTaskAndRule() throws {
        let machineKey = Data(0..<32)
        let envelope = try TaskRecurrence.automationTemplateCiphertext(taskId: "t1", ruleId: "r1", directory: "~/Projects/Radar",
                                                                      providerId: "codex", machineKey: machineKey)
        let parsed = try JSONValue.parse(Data(envelope.utf8))
        #expect(parsed["kind"] == "happier_automation_template_encrypted_v1")
        let payload = try #require(parsed["payloadCiphertext"]?.stringValue)
        let opened = try #require(AccountScopedBlob.open(payload, kind: .automationTemplatePayload, machineKey: machineKey))
        #expect(opened["agentTaskV1"] == ["taskId": "t1", "ruleId": "r1"])
        #expect(opened["directory"] == "~/Projects/Radar")
        #expect(opened["agent"] == "codex")
    }

    @Test func onlyClaudeAgentsGetTheAutomatedAccessWarning() {
        #expect(TaskRecurrence.needsAutomatedAccessWarning(providerId: "claude"))
        #expect(!TaskRecurrence.needsAutomatedAccessWarning(providerId: "codex"))
        #expect(!TaskRecurrence.needsAutomatedAccessWarning(providerId: nil))
    }
}

/// HTTP is the mocked boundary; request building and response parsing stay real.
private final class AutomationURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responder: ((URLRequest, Data) -> (Int, String))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                body.append(contentsOf: bytes.prefix(count))
            }
        }
        let (status, text) = Self.responder?(request, body) ?? (500, "{}")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct TaskRecurrenceAutomationAPITests {
    private func api() -> (HappierAPI, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AutomationURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return (HappierAPI(server: URL(string: "https://auto.invalid")!, token: "t", session: session), session)
    }

    @Test func createsOneCronAutomationPerRuleOnTheTasksMachine() async throws {
        AutomationURLProtocol.responder = { request, body in
            #expect(request.url?.path == "/v2/automations")
            #expect(request.httpMethod == "POST")
            let json = try! JSONValue.parse(body)
            #expect(json["name"] == "task t1 rule r1")
            #expect(json["enabled"] == true)
            #expect(json["schedule"] == ["kind": "cron", "scheduleExpr": "0 9 * * 1,2,3,4,5", "timezone": "America/Mexico_City"])
            #expect(json["targetType"] == "new_session")
            #expect(json["assignments"] == [["machineId": "m1"]])
            #expect(json["templateCiphertext"]?.stringValue == "TEMPLATE")
            return (200, #"{"id":"auto1","enabled":true,"nextRunAt":1794060000000}"#)
        }
        let (api, session) = api()
        defer { session.invalidateAndCancel() }
        let id = try await api.createTaskAutomation(taskId: "t1", rule: TaskRecurrenceTests.weekdays9, timezone: "America/Mexico_City",
                                                    enabled: true, machineId: "m1", templateCiphertext: "TEMPLATE")
        #expect(id == "auto1")
    }

    @Test func updatesPausesRunsAndDeletesByAutomationId() async throws {
        let seen = Recorder()
        AutomationURLProtocol.responder = { request, body in
            seen.add("\(request.httpMethod!) \(request.url!.path) \(String(decoding: body, as: UTF8.self))")
            return (200, request.url!.path.hasSuffix("run-now") ? #"{"run":{"id":"run1"}}"# : #"{"id":"auto1","ok":true}"#)
        }
        let (api, session) = api()
        defer { session.invalidateAndCancel() }
        try await api.updateTaskAutomation(id: "auto1", rule: TaskRecurrenceTests.weekend16, timezone: "UTC", machineId: "m2",
                                           templateCiphertext: "T2")
        try await api.setTaskAutomation(id: "auto1", paused: true)
        try await api.setTaskAutomation(id: "auto1", paused: false)
        try await api.runTaskAutomationNow(id: "auto1")
        try await api.deleteTaskAutomation(id: "auto1")
        let calls = seen.values
        #expect(calls[0].hasPrefix("PATCH /v2/automations/auto1 "))
        let patch = try JSONValue.parse(Data(calls[0].dropFirst("PATCH /v2/automations/auto1 ".count).utf8))
        #expect(patch["schedule"] == ["kind": "cron", "scheduleExpr": "0 16 * * 0,6", "timezone": "UTC"])
        #expect(patch["assignments"] == [["machineId": "m2"]])
        #expect(patch["templateCiphertext"] == "T2")
        #expect(calls[1].hasPrefix("POST /v2/automations/auto1/pause"))
        #expect(calls[2].hasPrefix("POST /v2/automations/auto1/resume"))
        #expect(calls[3].hasPrefix("POST /v2/automations/auto1/run-now"))
        #expect(calls[4].hasPrefix("DELETE /v2/automations/auto1"))
    }

    @Test func aRelayWithoutAutomationsSaysSo() async throws {
        AutomationURLProtocol.responder = { _, _ in (404, #"{"error":"Not Found"}"#) }
        let (api, session) = api()
        defer { session.invalidateAndCancel() }
        await #expect(throws: TaskRecurrence.AutomationsUnavailable.self) {
            _ = try await api.createTaskAutomation(taskId: "t1", rule: TaskRecurrenceTests.weekdays9, timezone: "UTC",
                                                   enabled: true, machineId: "m1", templateCiphertext: "T")
        }
        // A missing automation (already deleted elsewhere) isn't the relay lacking the feature.
        AutomationURLProtocol.responder = { _, _ in (404, #"{"error":"automation_not_found"}"#) }
        try await api.deleteTaskAutomation(id: "gone")
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ value: String) { lock.withLock { items.append(value) } }
    var values: [String] { lock.withLock { items } }
}

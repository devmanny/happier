import Foundation
import Testing
@testable import HappierKit

/// A one-time start ("Schedule…", `TaskScheduledStartV1Schema` in
/// `packages/protocol/src/tasks/agentTaskRecurrence.ts`) and assigning a task without starting it.
@Suite struct TaskScheduledStartTests {
    private static func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    static func task(_ overrides: [String: JSONValue] = [:]) -> AgentTask {
        var json: [String: JSONValue] = [
            "v": 1, "id": "t1", "title": "Publicar build", "status": "todo",
            "assignee": ["kind": "agent", "agentId": "a-mateo", "name": "Mateo"],
            "threads": [], "log": [], "createdAt": 0, "updatedAt": 0,
        ]
        for (key, value) in overrides { json[key] = value }
        return AgentTask(json: .object(json))!
    }

    @Test func cronMirrorsTheProtocolExamples() {
        #expect(TaskScheduledStart.cron(at: Self.date("2026-11-12T16:30:00Z"), timezone: "America/Mexico_City") == "30 10 12 11 *")
        #expect(TaskScheduledStart.cron(at: Self.date("2026-12-31T23:05:00Z"), timezone: "UTC") == "5 23 31 12 *")
        #expect(TaskScheduledStart.cron(at: .now, timezone: "Not/AZone") == nil)
    }

    @Test func scheduledStartParsesAndSurvivesOtherEdits() throws {
        let stored: JSONValue = ["at": 1_794_000_000_000, "timezone": "America/Mexico_City", "automationId": "auto9"]
        let task = Self.task(["scheduledStartV1": stored, "notifiedV1": ["dueSoonAt": 3]])
        let start = try #require(task.scheduledStart)
        #expect(start == TaskScheduledStart(at: 1_794_000_000_000, timezone: "America/Mexico_City", automationId: "auto9"))

        let edited = task.applying(AgentTask.Update(title: "Publicar"), now: 5)
        #expect(edited.json["scheduledStartV1"] == stored)
        #expect(edited.json["notifiedV1"] == ["dueSoonAt": 3])

        let moved = task.applying(AgentTask.Update(scheduledStart: .some(TaskScheduledStart(at: 1_794_100_000_000, timezone: "UTC",
                                                                                            automationId: "auto9"))), now: 6)
        #expect(moved.json["scheduledStartV1"] == ["at": 1_794_100_000_000, "timezone": "UTC", "automationId": "auto9"])
        #expect(task.applying(AgentTask.Update(scheduledStart: .some(nil)), now: 7).json["scheduledStartV1"] == nil)
        // Malformed or missing: no schedule shown.
        #expect(Self.task(["scheduledStartV1": ["timezone": "UTC"]]).scheduledStart == nil)
        #expect(Self.task().scheduledStart == nil)
    }

    @Test func assigningOnlyChangesWhoItIsFor() {
        let profile = AgentProfile(id: "a-leo", name: "Leo", emoji: "🦁", providerId: "codex", account: .init(label: ""))
        let update = AgentTask.Update.assigning(.agent(profile))
        #expect(update.status == nil)
        #expect(update.threadSessionId == nil)
        let assigned = Self.task().applying(update, now: 1)
        #expect(assigned.assignee.agentId == "a-leo")
        #expect(assigned.status == .todo)
        #expect(assigned.log.isEmpty)
        #expect(assigned.threads.isEmpty)
    }

    @Test func startingLinksTheSessionAndMarksItInProgress() {
        let started = Self.task().applying(.started(sessionId: "s1"), now: 1)
        #expect(started.status == .inProgress)
        #expect(started.threads == ["s1"])
    }

    @Test func reassigningCancelsAPendingStart() {
        let task = Self.task(["scheduledStartV1": ["at": 1, "timezone": "UTC", "automationId": "auto1"]])
        let update = task.scheduleAware(.assigning(.session(id: "s2", title: nil)))
        #expect(update.scheduledStart == .some(nil))
        // The same assignee, or no schedule: nothing to cancel.
        #expect(task.scheduleAware(.assigning(task.assignee)).scheduledStart == nil)
        #expect(Self.task().scheduleAware(.assigning(.user)).scheduledStart == nil)
    }

    @Test func scheduledTemplateCarriesTheTaskAndKind() throws {
        let machineKey = Data(0..<32)
        let envelope = try TaskScheduledStart.automationTemplateCiphertext(taskId: "t1", directory: "~/Projects/Radar",
                                                                          providerId: "codex", machineKey: machineKey)
        let parsed = try JSONValue.parse(Data(envelope.utf8))
        #expect(parsed["kind"] == "happier_automation_template_encrypted_v1")
        let payload = try #require(parsed["payloadCiphertext"]?.stringValue)
        let opened = try #require(AccountScopedBlob.open(payload, kind: .automationTemplatePayload, machineKey: machineKey))
        #expect(opened == ["directory": "~/Projects/Radar", "agent": "codex", "prompt": "Scheduled task",
                           "agentTaskV1": ["taskId": "t1", "kind": "scheduled_start"]])
    }

    // MARK: Session assignee

    @Test func aSessionAssigneeRoundTrips() throws {
        let titled = Self.task(["assignee": ["kind": "session", "sessionId": "s1", "title": "Arreglar login"]])
        #expect(titled.assignee == .session(id: "s1", title: "Arreglar login"))
        #expect(titled.assignee.sessionId == "s1")
        #expect(titled.assignee.agentId == nil)
        #expect(titled.json["assignee"] == ["kind": "session", "sessionId": "s1", "title": "Arreglar login"])
        let bare = Self.task(["assignee": ["kind": "session", "sessionId": "s2"]])
        #expect(bare.assignee == .session(id: "s2", title: nil))
        #expect(bare.json["assignee"] == ["kind": "session", "sessionId": "s2"])
        // A session without its id is nobody's: the task is kept, unassigned.
        #expect(AgentTask(json: Self.task().json.merging(["assignee": ["kind": "session"]]))?.assignee == .unassigned)
        // Linked to the session it's for, so "This Session" shows it.
        #expect(titled.linkedSessions.first == AgentTask.LinkedSession(sessionId: "s1", reasons: [.assigned]))
    }

    @Test func sessionsGroupAfterAgentsAndFilter() {
        let tasks = [
            Self.task(["id": "s-b", "assignee": ["kind": "session", "sessionId": "sb", "title": "Beta"]]),
            Self.task(["id": "mine", "assignee": ["kind": "user"]]),
            Self.task(["id": "s-a", "assignee": ["kind": "session", "sessionId": "sa", "title": "Alpha"]]),
            Self.task(["id": "agent"]),
        ]
        let sections = AgentTask.sections(tasks, scope: .all, openSessionId: nil, status: .open)
        #expect(sections.map { $0.tasks.map(\.id) } == [["mine"], ["agent"], ["s-a"], ["s-b"]])
        #expect(AgentTask.filter(tasks, assignee: .session("sa"), status: .open).map(\.id) == ["s-a"])
        let here = AgentTask.sections(tasks, scope: .thisSession, openSessionId: "sb", status: .open)
        #expect(here.first?.tasks.map(\.id) == ["s-b"])
    }

    @Test func theSessionStartMessageCarriesTheTaskContext() {
        let task = Self.task([
            "assignee": ["kind": "session", "sessionId": "s1"],
            "description": "Subir la build 42",
            "source": ["kind": "email", "label": "Correo de Ángel", "url": "https://mail.example/1"],
            "startAt": .number(1_794_000_000_000),
        ])
        let text = task.assignmentMessage(agentName: nil, timeZone: TimeZone(identifier: "UTC")!)
        #expect(text.hasPrefix("This task is now yours: Publicar build"))
        for piece in ["t1", "Subir la build 42", "Correo de Ángel", "https://mail.example/1", "2026-11-06 21:20", "tarea_actualizar (task id t1)"] {
            #expect(text.contains(piece))
        }
    }
}

private extension JSONValue {
    func merging(_ values: [String: JSONValue]) -> JSONValue {
        .object((objectValue ?? [:]).merging(values) { $1 })
    }
}

/// HTTP is the mocked boundary; request building stays real.
private final class ScheduleURLProtocol: URLProtocol, @unchecked Sendable {
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

@Suite(.serialized) struct TaskScheduledStartAPITests {
    private func api() -> (HappierAPI, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScheduleURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return (HappierAPI(server: URL(string: "https://schedule.invalid")!, token: "t", session: session), session)
    }

    @Test func createsOneOpaqueCronAutomationOnTheMachine() async throws {
        let bodies = Bodies()
        ScheduleURLProtocol.responder = { request, body in
            bodies.add("\(request.httpMethod!) \(request.url!.path)", body)
            return (200, #"{"id":"auto7"}"#)
        }
        let (api, session) = api()
        defer { session.invalidateAndCancel() }
        let at = ISO8601DateFormatter().date(from: "2026-11-12T16:30:00Z")!
        let start = TaskScheduledStart(at: at.timeIntervalSince1970 * 1000, timezone: "America/Mexico_City")
        let id = try await api.createScheduledStartAutomation(taskId: "t1", start: start, machineId: "m1", templateCiphertext: "TEMPLATE")
        #expect(id == "auto7")
        try await api.rescheduleStartAutomation(id: "auto7", start: TaskScheduledStart(at: 1_798_758_300_000, timezone: "UTC"))
        try await api.moveTaskAutomation(id: "auto7", machineId: "m2")

        let calls = bodies.values
        #expect(calls.map(\.0) == ["POST /v2/automations", "PATCH /v2/automations/auto7", "PATCH /v2/automations/auto7"])
        let create = try JSONValue.parse(calls[0].1)
        #expect(create == [
            "name": "task t1 start", "enabled": true, "targetType": "new_session",
            "schedule": ["kind": "cron", "scheduleExpr": "30 10 12 11 *", "timezone": "America/Mexico_City"],
            "templateCiphertext": "TEMPLATE", "assignments": [["machineId": "m1"]],
        ])
        #expect(try JSONValue.parse(calls[1].1) == ["schedule": ["kind": "cron", "scheduleExpr": "5 23 31 12 *", "timezone": "UTC"]])
        #expect(try JSONValue.parse(calls[2].1) == ["assignments": [["machineId": "m2"]]])
    }
}

private final class Bodies: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(String, Data)] = []
    func add(_ call: String, _ body: Data) { lock.withLock { items.append((call, body)) } }
    var values: [(String, Data)] { lock.withLock { items } }
}

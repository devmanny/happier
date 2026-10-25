import Foundation

/// A Happier execution run started from a session: a delegation to another agent, a review, a
/// voice agent… (`execution.run.list`, `ExecutionRunPublicStateSchema` in the protocol package).
public struct DelegatedRun: Identifiable, Equatable, Sendable {
    public let id: String
    /// `delegate`, `review`, `plan`, `voice_agent`…
    public let intent: String
    /// The built-in agent it runs on; nil for a configured ACP backend.
    public let agentId: String?
    /// A configured ACP backend's own id.
    public let backendId: String?
    /// The title it was started with, when it has one.
    public let title: String?
    /// `running`, `succeeded`, `failed`, `cancelled`, `timeout` (kept as sent, so a status added
    /// later still reads).
    public let status: String
    public let startedAt: Date
    public let finishedAt: Date?
    public let errorMessage: String?
    private let runClass: String?
    private let turnInFlight: Bool?

    /// Still doing work (`isExecutionRunActive`): a long-lived run waiting between turns is retained
    /// but idle.
    public var isActive: Bool { status == "running" && (runClass != "long_lived" || turnInFlight != false) }
    public var failed: Bool { ["failed", "timeout"].contains(status) }

    public init?(json: JSONValue) {
        guard let id = json["runId"]?.stringValue, let status = json["status"]?.stringValue,
              let started = json["startedAtMs"]?.doubleValue else { return nil }
        let target = json["backendTarget"]
        self.id = id
        self.status = status
        intent = json["intent"]?.stringValue ?? "delegate"
        agentId = target?["kind"]?.stringValue == "builtInAgent" ? target?["agentId"]?.stringValue : nil
        backendId = target?["kind"]?.stringValue == "configuredAcpBackend" ? target?["backendId"]?.stringValue : nil
        title = json["display"]?["title"]?.stringValue ?? json["display"]?["participantLabel"]?.stringValue
        startedAt = Date(timeIntervalSince1970: started / 1000)
        finishedAt = json["finishedAtMs"]?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) }
        errorMessage = json["error"]?["message"]?.stringValue ?? json["error"]?["code"]?.stringValue
        runClass = json["runClass"]?.stringValue
        turnInFlight = json["turnInFlight"]?.boolValue
    }

    /// The runs of an `execution.run.list` answer, newest first; rows that don't read are left out.
    public static func list(_ response: JSONValue) -> [DelegatedRun] {
        (response["runs"]?.arrayValue ?? []).compactMap(DelegatedRun.init(json:)).sorted { $0.startedAt > $1.startedAt }
    }
}

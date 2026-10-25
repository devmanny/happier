import Foundation

/// A command the agent left running in the background (`background_task.v1` session system
/// records, `backgroundTaskRecordV1.ts`).
public struct BackgroundCommand: Identifiable, Equatable, Sendable {
    public let id: String
    /// `command`, `monitoring` or `unknown`.
    public let kind: String
    /// `queued`, `starting`, `running`, `waiting`, `blocked`, `succeeded`, `failed`, `timedOut`, `cancelled`, `unknown`.
    public let status: String
    /// The command, redacted.
    public let label: String?
    public let summary: String?
    public let startedAt: Date?
    public let endedAt: Date?
    public let updatedAt: Date

    /// Still going (`deriveAgentActivityCounts.ts`).
    public var isLive: Bool { ["queued", "starting", "running", "blocked", "waiting"].contains(status) }
    public var failed: Bool { ["failed", "timedOut"].contains(status) }

    public init?(payload: JSONValue) {
        guard let id = payload["taskId"]?.stringValue, let status = payload["status"]?.stringValue else { return nil }
        func date(_ key: String) -> Date? {
            payload[key]?.doubleValue.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        }
        self.id = id
        self.status = status
        kind = payload["kind"]?.stringValue ?? "unknown"
        label = payload["label"]?.stringValue
        summary = payload["summary"]?.stringValue
        startedAt = date("startedAt")
        endedAt = date("endedAt")
        updatedAt = date("updatedAt") ?? .distantPast
    }
}

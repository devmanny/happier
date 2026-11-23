import Foundation

/// A workflow the agent runs (Claude's `Workflow` tool: many agents in phases), from its
/// `activity/workflow_run.v1` record (`SessionWorkflowRunSnapshotV1`). The daemon counts it in the
/// background like a subagent, but it is no subagent tool call, so this is what lists it.
public struct WorkflowRun: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// `active`, `complete`, `failed`, `stopped`, `blocked`, `cancelled`, `unknown`.
    public let status: String
    public let totalAgents: Int
    public let completedAgents: Int
    public let startedAt: Date?
    public let completedAt: Date?
    public let updatedAt: Date

    /// Not ended yet (`isTerminalWorkflowRunStatus`): blocked and unknown runs still count.
    public var isLive: Bool { !["complete", "failed", "stopped", "cancelled"].contains(status) }
    public var failed: Bool { status == "failed" }

    public init?(payload: JSONValue) {
        // Another projection of the record would be read wrong (`SESSION_WORKFLOW_RUN_SNAPSHOT_PROJECTION_VERSION`).
        guard payload["v"]?.intValue == 1, payload["projectionVersion"]?.intValue == 1,
              let id = payload["runId"]?.stringValue, let title = payload["title"]?.stringValue,
              let status = payload["status"]?.stringValue else { return nil }
        func date(_ key: String) -> Date? {
            payload[key]?.doubleValue.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        }
        self.id = id
        self.title = title
        self.status = status
        totalAgents = payload["totalAgents"]?.intValue ?? 0
        completedAgents = payload["completedAgents"]?.intValue ?? 0
        startedAt = date("startedAt")
        completedAt = date("completedAt")
        updatedAt = date("updatedAt") ?? .distantPast
    }
}

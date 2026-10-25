import Foundation

/// The goal the agent keeps pursuing across turns (Codex app-server goals, Claude `/goal`), as
/// the runtime publishes it in the session's work state (`sessionWorkStatePresentation.ts`).
public struct SessionGoal: Equatable, Sendable {
    public enum Status: String, Sendable {
        case pending, active, paused, blocked, complete, cancelled, unknown
    }

    public struct Controls: Equatable, Sendable {
        public let canSet: Bool
        public let canClear: Bool
    }

    public let objective: String
    public let status: Status

    /// Still being pursued or waiting to be resumed; finished goals give way to setting a new one.
    public var isOngoing: Bool { status != .complete && status != .cancelled }

    /// `sessionWorkStateV1` (the primary goal item first), else the legacy `sessionGoalV1`/`codexGoalV1`.
    public static func current(in metadata: JSONValue) -> SessionGoal? {
        if let state = metadata["sessionWorkStateV1"], let items = state["items"]?.arrayValue {
            let goals = items.filter { $0["kind"]?.stringValue == "goal" }
            let primary = state["primaryItemId"]?.stringValue
            if let item = goals.first(where: { $0["id"]?.stringValue == primary }) ?? goals.first {
                return goal(title: item["title"]?.stringValue, status: item["status"]?.stringValue)
            }
            return nil
        }
        guard let legacy = metadata["sessionGoalV1"] ?? metadata["codexGoalV1"] else { return nil }
        return goal(title: legacy["objective"]?.stringValue ?? legacy["title"]?.stringValue, status: legacy["status"]?.stringValue)
    }

    /// What the running agent accepts (`sessionGoalSetSupported` / `sessionGoalClearSupported`).
    public static func controls(agentState: JSONValue) -> Controls {
        let capabilities = agentState["capabilities"]
        return Controls(canSet: capabilities?["sessionGoalSetSupported"]?.boolValue == true,
                        canClear: capabilities?["sessionGoalClearSupported"]?.boolValue == true)
    }

    private static func goal(title: String?, status: String?) -> SessionGoal? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return SessionGoal(objective: title, status: status.flatMap(Status.init(rawValue:)) ?? .active)
    }
}

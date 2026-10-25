import Foundation

/// A session runner still on an older CLI than its daemon, with a restart the daemon allows.
public struct StaleRunner: Equatable, Sendable {
    public let sessionId: String
    public let machineId: String
    public let expectedRunnerPid: Int
    public let expectedProcessCommandHash: String
    public let expectedRunnerEntrypointIdentity: String
}

/// The "session still runs an older CLI" notice (`sessionRunnerRuntimeStatus.ts`,
/// `sessionRunnerRestart.ts`): the daemon reports runner/daemon versions through
/// `daemon.sessionRunner.status.get` and restarts the runner on the current CLI on request.
public enum SessionRunner {
    public enum Outcome: Equatable, Sendable {
        case restarted
        /// A turn or approval is in progress; try again when it finishes.
        case busy
        case failed
    }

    public static let statusMethod = "daemon.sessionRunner.status.get"
    public static let restartMethod = "daemon.sessionRunner.restart"

    /// `state` is a `SessionRunnerRuntimeStateV1` from `statusMethod`.
    public static func staleRunner(sessionId: String, machineId: String?, state: JSONValue) -> StaleRunner? {
        guard state["v"]?.intValue == 1, state["sessionId"]?.stringValue == sessionId,
              let machineId = nonEmpty(machineId), nonEmpty(state["machineId"]?.stringValue) == machineId,
              state["versionState"]?.stringValue == "stale"
        else { return nil }
        let planned = state["plannedRestart"] ?? .null
        guard planned["supported"]?.boolValue == true, planned["eligible"]?.boolValue == true,
              nonEmpty(planned["disabledReason"]?.stringValue) == nil
        else { return nil }
        let runner = state["runner"] ?? .null
        let daemon = state["daemon"] ?? .null
        guard let pid = runner["pid"]?.intValue, pid > 0,
              let commandHash = nonEmpty(runner["processCommandHash"]?.stringValue),
              runner["entrypointSource"]?.stringValue != "unknown",
              let runnerIdentity = nonEmpty(runner["runtimeId"]?.stringValue),
              daemon["currentEntrypointSource"]?.stringValue != "unknown",
              nonEmpty(daemon["currentEntrypointVersion"]?.stringValue) != nil
        else { return nil }
        return StaleRunner(sessionId: sessionId, machineId: machineId, expectedRunnerPid: pid,
                           expectedProcessCommandHash: commandHash, expectedRunnerEntrypointIdentity: runnerIdentity)
    }

    /// `RestartSessionRunnerRequestV1` as the UI's composer banner sends it.
    public static func restartRequest(_ stale: StaleRunner) -> JSONValue {
        [
            "sessionId": .string(stale.sessionId), "mode": "if_stale", "reason": "ui_stale_runner_banner",
            "expectedRunnerPid": .number(Double(stale.expectedRunnerPid)),
            "expectedProcessCommandHash": .string(stale.expectedProcessCommandHash),
            "expectedRunnerEntrypointIdentity": .string(stale.expectedRunnerEntrypointIdentity),
        ]
    }

    public static func outcome(_ result: JSONValue) -> Outcome {
        switch (result["ok"]?.boolValue, result["status"]?.stringValue) {
        case (true, "restarted"), (true, "already_current"): .restarted
        case (false, "busy"): .busy
        default: .failed
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }
}

/// The `rpc-call` envelope for a machine-scoped RPC (`apiSocket.ts`).
public enum MachineRPCCall {
    public static func payload(machineId: String, method: String, params: JSONValue, timeoutMs: Int,
                               authorizingSession sessionId: String?) -> JSONValue {
        var call: [String: JSONValue] = [
            "method": .string("\(machineId):\(method)"), "params": params, "timeoutMs": .number(Double(timeoutMs)),
        ]
        if let sessionId { call["authorization"] = ["kind": "session.write", "sessionId": .string(sessionId)] }
        return .object(call)
    }
}

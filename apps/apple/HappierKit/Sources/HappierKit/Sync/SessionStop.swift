import Foundation

/// Stopping a session (`apps/ui/sources/sync/ops/sessionStopStrategy.ts`): ask the supervising
/// daemon (`stop-session` machine RPC) first, then the runner itself (`killSession` session RPC).
public enum SessionStop {
    public enum Outcome: Equatable, Sendable {
        /// The process is gone.
        case stopped
        /// Stop was accepted; the session turns inactive shortly.
        case requested
        /// The daemon can't stop it; ask the runner.
        case fallback
        case failed(String)
    }

    /// `StopSessionResultSchema` from the daemon, plus released acknowledgement shapes.
    public static func daemonOutcome(_ response: JSONValue) -> Outcome {
        switch response["status"]?.stringValue {
        case "stopped": return .stopped
        case "requested": return .requested
        case "not_found": return .fallback
        case "incomplete":
            let reason = response["reason"]?.stringValue ?? "unknown"
            return reason == "tracked_runner_absent" ? .fallback : .failed("Session stop incomplete: \(reason)")
        default: break
        }
        if response["message"]?.stringValue == "Session stopped" { return .requested }
        if let error = response["error"]?.stringValue,
           error == "Session not found or failed to stop" || RPCErrorCodes.unavailable.contains(response["errorCode"]?.stringValue ?? "") {
            return .fallback
        }
        if let error = response["error"]?.stringValue { return .failed(error) }
        return .failed("Unsupported response from machine RPC")
    }

    /// A live runner can acknowledge a stop request but cannot prove its own exit.
    public static func runnerOutcome(_ response: JSONValue) -> Outcome {
        switch response["status"]?.stringValue {
        case "stopped", "requested": return .requested
        case "not_found": return .failed("Session not found")
        case "incomplete": return .failed("Session stop incomplete: \(response["reason"]?.stringValue ?? "unknown")")
        default: break
        }
        if response["success"]?.boolValue == true { return .requested }
        return .failed(response["message"]?.stringValue ?? "Failed to stop session")
    }
}

enum RPCErrorCodes {
    /// The RPC target isn't connected or doesn't implement the method.
    static let unavailable: Set<String> = ["RPC_METHOD_NOT_AVAILABLE", "RPC_METHOD_NOT_FOUND"]
}

import Foundation

/// A user's answer to a pending permission request (`PermissionFooter.tsx` button mapping).
public enum PermissionReply: Sendable, Equatable {
    case allow
    case allowForSession
    case allowAllEdits
    case deny(reason: String?)
    /// Deny and stop the current turn.
    case stop

    /// Agents whose UI core declares `promptProtocol: 'codexDecision'`.
    static let decisionProtocolAgents: Set<String> = ["codex", "gemini", "cursor", "copilot", "kilo", "devin", "droid", "fx"]

    func payload(requestId: String, tool: String, agentId: String?) -> JSONValue {
        let decisionStyle = agentId.map(Self.decisionProtocolAgents.contains) ?? false
        var body: [String: JSONValue] = ["id": .string(requestId)]
        switch self {
        case .allow:
            body["approved"] = true
            if decisionStyle { body["decision"] = "approved" }
        case .allowForSession:
            body["approved"] = true
            if decisionStyle { body["decision"] = "approved_for_session" } else { body["allowedTools"] = [.string(tool)] }
        case .allowAllEdits:
            body["approved"] = true
            if decisionStyle { body["decision"] = "approved" } else { body["mode"] = "acceptEdits" }
        case .deny(let reason):
            body["approved"] = false
            body["decision"] = "denied"
            if let reason, !reason.isEmpty { body["reason"] = .string(reason) }
        case .stop:
            body["approved"] = false
            body["decision"] = decisionStyle ? "denied" : "abort"
        }
        return .object(body)
    }

    /// Whether the reply should be followed by the session `abort` RPC (Codex: deny only).
    func abortsTurn(agentId: String?) -> Bool {
        guard case .stop = self else { return false }
        return !(agentId.map(Self.decisionProtocolAgents.contains) ?? false)
    }
}

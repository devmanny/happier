import Foundation

/// An explicit resume of the same conversation through `spawn-happy-session`.
/// The daemon's `resolveSessionRuntimeSnapshot` restores the saved model, permissions,
/// connected services and provider conversation. Do not seed new-session defaults here.
public struct SessionResumeRequest: Sendable {
    public let machineId: String
    public let params: JSONValue

    public init(session: Session, requestId: String) throws {
        guard let machineId = Self.nonempty(session.machineId),
              let directory = Self.nonempty(session.path) else {
            throw HappierStore.RPCError(message: String(localized: "This session has no saved computer or folder to resume from."), code: nil)
        }
        let metadata = session.metadata
        let runtime = metadata["agentRuntimeDescriptorV1"]
        let agentId: String?
        if let runtime {
            guard runtime["v"]?.intValue == 1, runtime["provider"]?.objectValue != nil,
                  let provider = runtime["providerId"]?.stringValue, Agent.ids.contains(provider) else {
                throw HappierStore.RPCError(message: String(localized: "The saved agent identity is unsupported. Update Happier before resuming this session."), code: nil)
            }
            agentId = provider
        } else {
            agentId = session.agentId
        }
        let target: JSONValue
        if let configured = metadata["acpConfiguredBackendV1"] {
            guard configured["v"]?.intValue == 1, let backendId = Self.nonempty(configured["backendId"]?.stringValue),
                  agentId == "customAcp",
                  metadata["flavor"]?.stringValue.map({ !$0.hasPrefix("acp:") || $0 == "acp:\(backendId)" }) ?? true else {
                throw HappierStore.RPCError(message: String(localized: "The saved agent configuration can't be resumed."), code: nil)
            }
            target = ["kind": "configuredAcpBackend", "backendId": .string(backendId)]
        } else if let agentId, agentId != "customAcp" {
            target = ["kind": "builtInAgent", "agentId": .string(agentId)]
        } else {
            throw HappierStore.RPCError(message: String(localized: "This session has no supported agent to resume."), code: nil)
        }
        var params: [String: JSONValue] = [
            "type": "resume-session", "sessionId": .string(session.id), "directory": .string(directory),
            "backendTarget": target,
            "executionAuthorization": ["provenance": "user_request", "requestId": .string(requestId)],
        ]
        if let runtime { params["agentRuntimeDescriptorV1"] = runtime }
        self.machineId = machineId
        self.params = .object(params)
    }

    /// Only the daemon's acknowledgement for this exact conversation is a successful resume.
    public static func validate(_ response: JSONValue, sessionId: String) throws {
        guard response["type"]?.stringValue == "success", response["sessionId"]?.stringValue == sessionId else {
            throw HappierStore.RPCError(message: response["errorMessage"]?.stringValue
                ?? String(localized: "The computer couldn't reactivate this session. Check its connection and try again."), code: nil)
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}

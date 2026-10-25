import Foundation

/// Unix time in whole milliseconds, the form every Happier writer uses (`Date.now()` in JS).
/// The daemon rejects fractional spawn timestamps (`z.number().int()`).
public enum ServerClock {
    public static func nowMs() -> Double { (Date.now.timeIntervalSince1970 * 1000).rounded(.down) }
}

/// Params for the daemon's `spawn-happy-session` RPC (`spawnSessionPayload.ts`).
public enum SpawnRequest {
    /// `modelId` seeds the session's model override (`"default"` or nil keeps the CLI settings);
    /// `effort` seeds the `reasoning_effort` config option, as the new-session screen does.
    public static func params(directory: String, agentId: String, permissionMode: PermissionMode, modelId: String? = nil,
                              effort: String? = nil, nonce: String, approveNewDirectory: Bool,
                              now: Double = ServerClock.nowMs()) -> JSONValue {
        let now = now.rounded(.down)
        var params: [String: JSONValue] = [
            "type": "spawn-in-directory", "directory": .string(directory), "approvedNewDirectoryCreation": .bool(approveNewDirectory),
            "backendTarget": ["kind": "builtInAgent", "agentId": .string(agentId)], "spawnNonce": .string(nonce),
            "permissionMode": .string(permissionMode.rawValue), "permissionModeUpdatedAt": .number(now),
        ]
        if let modelId, !modelId.isEmpty, modelId != "default" {
            params["modelId"] = .string(modelId)
            params["modelUpdatedAt"] = .number(now)
        }
        if let overrides = effortOverrides(effort, now: now) { params["sessionConfigOptionOverrides"] = overrides }
        return .object(params)
    }

    /// `sessionConfigOptionOverrides` seeding `reasoning_effort`; nil when there's no effort to seed.
    static func effortOverrides(_ effort: String?, now: Double) -> JSONValue? {
        guard let effort, !effort.isEmpty else { return nil }
        return ["v": 1, "updatedAt": .number(now), "overrides": ["reasoning_effort": ["updatedAt": .number(now), "value": .string(effort)]]]
    }
}

/// Params for the daemon's `session.agentTransition` RPC (`SessionAgentTransitionRequestV1`): the
/// session continues with another agent, whose first message is `text`. The picked model and effort
/// travel like a new session's (`SpawnRequest`).
public enum AgentTransitionRequest {
    public static func params(sessionId: String, currentAgentId: String, selection: HappierStore.AgentSelection,
                              text: String, localId: String, meta: [String: JSONValue], now: Double = ServerClock.nowMs()) -> JSONValue {
        let now = now.rounded(.down)
        var target: [String: JSONValue] = ["v": 1, "agentId": .string(selection.agentId)]
        if let model = selection.modelId, !model.isEmpty, model != "default" { target["modelId"] = .string(model) }
        if let overrides = SpawnRequest.effortOverrides(selection.effort, now: now) { target["sessionConfigOptionOverrides"] = overrides }
        return [
            "v": 1, "sessionId": .string(sessionId), "expectedCurrentAgentId": .string(currentAgentId),
            "selection": .object(target),
            "input": ["text": .string(text), "localId": .string(localId), "meta": .object(meta)],
        ]
    }
}

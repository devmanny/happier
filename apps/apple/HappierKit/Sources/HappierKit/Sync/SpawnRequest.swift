import Foundation

/// Unix time in whole milliseconds, the form every Happier writer uses (`Date.now()` in JS).
/// The daemon rejects fractional spawn timestamps (`z.number().int()`).
public enum ServerClock {
    public static func nowMs() -> Double { (Date.now.timeIntervalSince1970 * 1000).rounded(.down) }
}

/// Params for the daemon's `spawn-happy-session` RPC (`spawnSessionPayload.ts`).
public enum SpawnRequest {
    public static func params(directory: String, agentId: String, permissionMode: PermissionMode,
                              nonce: String, approveNewDirectory: Bool, now: Double = ServerClock.nowMs()) -> JSONValue {
        [
            "type": "spawn-in-directory", "directory": .string(directory), "approvedNewDirectoryCreation": .bool(approveNewDirectory),
            "backendTarget": ["kind": "builtInAgent", "agentId": .string(agentId)], "spawnNonce": .string(nonce),
            "permissionMode": .string(permissionMode.rawValue), "permissionModeUpdatedAt": .number(now.rounded(.down)),
        ]
    }
}

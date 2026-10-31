import HappierKit

/// A session started from a sentence alone (the Apple Watch, Siri, the Action button): it runs
/// where the new-session screen last did (`NewSessionDefaults`), with that agent's default
/// permissions, and opens in the app when it's next in front.
enum QuickSessionStart {
    @MainActor
    static func start(_ text: String, store: HappierStore) async -> WatchReply {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return .failed(String(localized: "Say what to work on.")) }
        // Possibly woken in the background just for this.
        store.restore()
        guard store.phase == .ready else { return .failed(String(localized: "Sign in to Happier on your iPhone first.")) }
        await store.refreshMachines()
        if !store.hasLoadedSessions { await store.refreshSessions() }
        guard let choice = NewSessionDefaults.resolve(machines: store.machines, sessions: Array(store.sessions.values), defaults: .standard) else {
            return .failed(String(localized: "No machine is online."))
        }
        if store.accountSettings == nil { await store.refreshAccountSettings() }
        let mode = store.accountSettings?.defaultPermissionMode(for: choice.agentId) ?? .yolo
        let outcome = await store.createSession(machineId: choice.machineId, directory: choice.directory, agentId: choice.agentId,
                                                permissionMode: mode, modelId: choice.modelId, effort: choice.effort, firstMessage: message)
        switch outcome {
        case .created(let sessionId): return .done(sessionId: sessionId)
        case .needsDirectoryApproval(let folder): return .failed(String(localized: "\(folder) is gone from the machine. Start from your iPhone."))
        case .failed(let reason): return .failed(reason)
        }
    }
}

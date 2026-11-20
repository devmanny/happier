import Foundation

/// Where a session started without choices (the Apple Watch, Siri, the Action button) runs: what
/// the new-session screen last used. Its agent, model and effort are remembered under these keys;
/// the machine and folder follow the latest session on a machine that's online now.
public struct NewSessionDefaults: Equatable, Sendable {
    public static let agentKey = "happier.newSession.agent"
    public static func modelKey(_ agent: String) -> String { "happier.newSession.model.\(agent)" }
    public static func effortKey(_ agent: String) -> String { "happier.newSession.effort.\(agent)" }

    public let machineId: String
    public let directory: String
    public let agentId: String
    /// nil keeps the agent's CLI settings.
    public let modelId: String?
    public let effort: String?

    /// nil when no machine is online, so nothing could start.
    public static func resolve(machines: [Machine], sessions: [Session], defaults: UserDefaults, now: Date = .now) -> NewSessionDefaults? {
        let online = Machine.visible(machines, now: now).filter { $0.isOnline(at: now) }
        guard !online.isEmpty else { return nil }
        let onlineIds = Set(online.map(\.id))
        let latest = sessions.sorted { $0.sortDate > $1.sortDate }.first { $0.machineId.map(onlineIds.contains) == true }
        guard let machine = latest.flatMap({ session in online.first { $0.id == session.machineId } }) ?? online.first else { return nil }
        let directory = Machine.recentDirectories(machineId: machine.id, sessions: sessions).first ?? machine.homeDir ?? ""
        guard !directory.isEmpty else { return nil }

        let agent: String
        if let remembered = defaults.string(forKey: agentKey), !remembered.isEmpty {
            agent = remembered
        } else {
            var counts: [String: Int] = [:]
            for session in sessions { if let id = session.agentId { counts[id, default: 0] += 1 } }
            agent = counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? "claude"
        }
        let model = defaults.string(forKey: modelKey(agent)).flatMap { $0.isEmpty || $0 == "default" ? nil : $0 }
        let effort = defaults.string(forKey: effortKey(agent)).flatMap { $0.isEmpty ? nil : $0 }
        return NewSessionDefaults(machineId: machine.id, directory: directory, agentId: agent, modelId: model, effort: effort)
    }
}

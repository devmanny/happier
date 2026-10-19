import Foundation

/// Device-local message pins (`sessionMessagePins.ts`): never synced, scoped per server/account.
public struct MessagePins: Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant, tool }

    public struct Pin: Codable, Sendable, Equatable {
        public let seq: Int
        public let role: Role
        public let pinnedAtMs: Double
    }

    private nonisolated(unsafe) let defaults: UserDefaults
    private let key: String
    private var sessions: [String: [Pin]]

    public init(defaults: UserDefaults = .standard, scope: String) {
        self.defaults = defaults
        key = "session-message-pins-v1:scope:v2:\(scope)"
        sessions = (defaults.data(forKey: key)).flatMap { try? JSONDecoder().decode([String: [Pin]].self, from: $0) } ?? [:]
    }

    public func pinned(sessionId: String) -> [Pin] { sessions[sessionId] ?? [] }

    public func isPinned(sessionId: String, seq: Int) -> Bool { pinned(sessionId: sessionId).contains { $0.seq == seq } }

    public mutating func toggle(sessionId: String, seq: Int, role: Role) {
        var list = sessions[sessionId] ?? []
        if let index = list.firstIndex(where: { $0.seq == seq }) {
            list.remove(at: index)
        } else {
            list.append(Pin(seq: seq, role: role, pinnedAtMs: Date.now.timeIntervalSince1970 * 1000))
            list.sort { ($0.seq, $0.pinnedAtMs) < ($1.seq, $1.pinnedAtMs) }
        }
        sessions[sessionId] = list.isEmpty ? nil : list
        if let data = try? JSONEncoder().encode(sessions) { defaults.set(data, forKey: key) }
    }
}

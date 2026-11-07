import Foundation

/// Keeps tasks, agent profiles and agent memory current from the relay's UserKVStore events
/// (`apps/server/sources/app/kv/kvMutate.ts`): every write is pushed on the socket as
/// `kv-batch-update` with each changed key's sealed value and version, so the app applies it
/// without re-reading. After a reconnect it catches up through the account's change cursor
/// (`/v2/changes`). The relay coalesces KV changes into one row whose hint names only the last
/// write's keys, so a KV change seen there re-reads the prefixes this app shows (tasks, profiles,
/// loaded memories) rather than trusting those keys.
public enum AccountKVSync {
    public struct Change: Equatable, Sendable {
        public let key: String
        /// The sealed value; nil when the key was deleted.
        public let value: String?
        public let version: Int

        public init(key: String, value: String?, version: Int) {
            self.key = key
            self.value = value
            self.version = version
        }
    }

    /// The changes in a `kv-batch-update` update body; empty for any other update.
    public static func changes(fromUpdate body: JSONValue) -> [Change] {
        guard body["t"]?.stringValue == "kv-batch-update" else { return [] }
        return (body["changes"]?.arrayValue ?? []).compactMap { change in
            guard let key = change["key"]?.stringValue, let version = change["version"]?.intValue else { return nil }
            let value = change["value"]?.stringValue
            return Change(key: key, value: value?.isEmpty == false ? value : nil, version: version)
        }
    }

    /// What a catch-up must read again.
    public struct Refresh: Equatable, Sendable {
        public var tasks: Bool
        public var profiles: Bool
        /// Agent memory (only the agents open here).
        public var memory: Bool

        public init(tasks: Bool, profiles: Bool, memory: Bool) {
            self.tasks = tasks
            self.profiles = profiles
            self.memory = memory
        }

        public static let none = Refresh(tasks: false, profiles: false, memory: false)
        public static let all = Refresh(tasks: true, profiles: true, memory: true)

        public var isEmpty: Bool { self == .none }

        func union(_ other: Refresh) -> Refresh {
            Refresh(tasks: tasks || other.tasks, profiles: profiles || other.profiles, memory: memory || other.memory)
        }

        /// A KV change row's family (`accountKvChangeFamily` in the protocol): presence is never
        /// read again; the historical `self` row (older relays) or an unknown family reads all.
        static func family(_ entityId: String?) -> Refresh {
            switch entityId {
            case "presence": .none
            case "task": Refresh(tasks: true, profiles: false, memory: false)
            case "agentprofile": Refresh(tasks: false, profiles: true, memory: false)
            case "agent": Refresh(tasks: false, profiles: true, memory: true)
            default: .all
            }
        }
    }

    public struct Page: Equatable, Sendable {
        public let refresh: Refresh
        public let nextCursor: Int?
        /// Entries of every kind, to tell a full page from the last one.
        public let count: Int

        public var touchedKV: Bool { !refresh.isEmpty }
    }

    /// A `/v2/changes` page, reduced to what of the KV store must be read again.
    public static func page(_ response: JSONValue) -> Page {
        let changes = response["changes"]?.arrayValue ?? []
        let refresh = changes.filter { $0["kind"]?.stringValue == "kv" }
            .reduce(Refresh.none) { $0.union(.family($1["entityId"]?.stringValue)) }
        return Page(refresh: refresh, nextCursor: response["nextCursor"]?.intValue, count: changes.count)
    }
}

extension AgentMemory {
    /// The memory with one changed record applied (nil value: removed).
    func applying(_ change: AccountKVSync.Change, machineKey: Data) -> AgentMemory {
        let parts = change.key.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4, parts[0] == "agent" else { return self }
        var next = self
        switch (parts[2], parts.count) {
        case ("now", 4): next.now.removeAll { $0.sessionId == parts[3] }
        case ("journal", 5): next.journal.removeAll { $0.id == parts[4] && $0.day == parts[3] }
        case ("note", 4): next.notes.removeAll { $0.id == parts[3] }
        default: return self
        }
        if let value = change.value {
            let added = AgentMemory(fromList: ["items": [["key": .string(change.key), "value": .string(value),
                                                          "version": .number(Double(change.version))]]], machineKey: machineKey)
            next.now += added.now
            next.journal += added.journal
            next.notes += added.notes
        }
        next.now.sort { $0.updatedAt > $1.updatedAt }
        next.journal.sort { $0.at > $1.at }
        next.notes.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return next
    }
}

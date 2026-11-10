import Foundation

/// A room ("sala", `packages/protocol/src/rooms/agentRoom.ts`): a group chat of the user and the
/// agents they invite, each working from its own folder on one machine. Sealed for the account's
/// devices under kind `agent_room`, with opaque keys: `room/<id>` (this), `roommsg/<id>/<seq>` (each
/// message, created with version -1 in the same write that moves `lastSeq`) and
/// `roomseat/<id>/<agentId>` (a member's thread and read marker, written by its daemon). The daemon
/// of each member's machine delivers what mentions it; this app writes the room and the user's
/// messages. Keys this build doesn't know are kept on rewrite.
public struct AgentRoom: Identifiable, Sendable, Equatable {
    public struct Member: Identifiable, Sendable, Equatable {
        public let agentId: String
        public var name: String?
        public var emoji: String?
        public var machineId: String
        public var directory: String
        /// Another agent's mention starts a turn for it (set after the Consumer Terms warning for
        /// Claude); otherwise only the user's mentions do.
        public var wakeByAgents: Bool?
        /// The protocol's intent name (`read_only`, `default`, `auto`, `yolo`); nil is YOLO.
        public var permissionMode: String?
        var extra: [String: JSONValue] = [:]

        public var id: String { agentId }

        public init(agentId: String, name: String?, emoji: String? = nil, machineId: String, directory: String,
                    wakeByAgents: Bool? = nil, permissionMode: String? = nil) {
            self.agentId = agentId
            self.name = name
            self.emoji = emoji
            self.machineId = machineId
            self.directory = directory
            self.wakeByAgents = wakeByAgents
            self.permissionMode = permissionMode
        }

        /// The member for an agent of the account.
        public init(_ agent: AgentProfile, machineId: String, directory: String, wakeByAgents: Bool) {
            self.init(agentId: agent.id, name: agent.name, emoji: agent.emoji, machineId: machineId, directory: directory,
                      wakeByAgents: wakeByAgents)
        }

        init?(json: JSONValue) {
            guard let agentId = json["agentId"]?.stringValue, !agentId.isEmpty,
                  let machineId = json["machineId"]?.stringValue, !machineId.isEmpty,
                  let directory = json["directory"]?.stringValue, !directory.isEmpty else { return nil }
            self.init(agentId: agentId, name: json["name"]?.stringValue, emoji: json["emoji"]?.stringValue, machineId: machineId,
                      directory: directory, wakeByAgents: json["wakeByAgents"]?.boolValue, permissionMode: json["permissionMode"]?.stringValue)
            let known: Set<String> = ["agentId", "name", "emoji", "machineId", "directory", "wakeByAgents", "permissionMode"]
            extra = (json.objectValue ?? [:]).filter { !known.contains($0.key) }
        }

        var json: JSONValue {
            var object = extra
            object["agentId"] = .string(agentId)
            if let name, !name.isEmpty { object["name"] = .string(name) }
            if let emoji, !emoji.isEmpty { object["emoji"] = .string(emoji) }
            object["machineId"] = .string(machineId)
            object["directory"] = .string(directory)
            if let wakeByAgents { object["wakeByAgents"] = .bool(wakeByAgents) }
            if let permissionMode { object["permissionMode"] = .string(permissionMode) }
            return .object(object)
        }
    }

    public let id: String
    public var title: String
    /// How the members call the user (and mention them); "User" when absent.
    public var userName: String?
    public var members: [Member]
    /// The seq of the last message; 0 before the first.
    public var lastSeq: Int
    /// The pause button: nothing is delivered until it is cleared; running turns finish.
    public var pausedAt: Double?
    public var archivedAt: Double?
    public var createdAt: Double
    public var updatedAt: Double
    /// The UserKVStore version this copy was read at (-1 for a room not stored yet).
    public var version = -1
    var extra: [String: JSONValue] = [:]

    public var isPaused: Bool { pausedAt != nil }

    public init(id: String = UUID().uuidString.lowercased(), title: String, userName: String?, members: [Member],
                now: Double = ServerClock.nowMs()) {
        self.id = id.lowercased()
        self.title = title
        self.userName = userName
        self.members = members
        self.lastSeq = 0
        self.createdAt = now
        self.updatedAt = now
    }

    init?(json: JSONValue) {
        guard json["v"]?.intValue == 1, let id = json["id"]?.stringValue, !id.isEmpty,
              let title = json["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              let lastSeq = json["lastSeq"]?.intValue, lastSeq >= 0 else { return nil }
        self.id = id
        self.title = title
        self.userName = json["userName"]?.stringValue
        self.members = json["members"]?.arrayValue?.compactMap(Member.init(json:)) ?? []
        self.lastSeq = lastSeq
        self.pausedAt = json["pausedAt"]?.doubleValue
        self.archivedAt = json["archivedAt"]?.doubleValue
        self.createdAt = json["createdAt"]?.doubleValue ?? 0
        self.updatedAt = json["updatedAt"]?.doubleValue ?? 0
        let known: Set<String> = ["v", "id", "title", "userName", "members", "lastSeq", "pausedAt", "archivedAt", "createdAt", "updatedAt"]
        self.extra = (json.objectValue ?? [:]).filter { !known.contains($0.key) }
    }

    var json: JSONValue {
        var object = extra
        object["v"] = 1
        object["id"] = .string(id)
        object["title"] = .string(title)
        if let userName, !userName.trimmingCharacters(in: .whitespaces).isEmpty { object["userName"] = .string(userName) }
        object["members"] = .array(members.map(\.json))
        object["lastSeq"] = .number(Double(lastSeq))
        if let pausedAt { object["pausedAt"] = .number(pausedAt) }
        if let archivedAt { object["archivedAt"] = .number(archivedAt) }
        object["createdAt"] = .number(createdAt)
        object["updatedAt"] = .number(updatedAt)
        return .object(object)
    }

    // MARK: Storage

    public static let kvPrefix = "room/"

    public static func kvKey(id: String) -> String { kvPrefix + id }

    func sealed(machineKey: Data) throws -> String {
        try AccountScopedBlob.seal(json, kind: .agentRoom, machineKey: machineKey)
    }

    static func open(_ base64: String, machineKey: Data) -> AgentRoom? {
        AccountScopedBlob.open(base64, kind: .agentRoom, machineKey: machineKey).flatMap(AgentRoom.init(json:))
    }

    // MARK: Sidebar selection

    private static let selectionPrefix = "happier.room:"

    /// The sidebar's selection for this room, which opens like a session (never a session's id).
    public static func selection(id: String) -> String { selectionPrefix + id }

    /// The room `selection` names; nil for a session, an agent or nothing.
    public static func id(inSelection selection: String?) -> String? {
        guard let selection, selection.hasPrefix(selectionPrefix) else { return nil }
        let id = String(selection.dropFirst(selectionPrefix.count))
        return id.isEmpty ? nil : id
    }

    // MARK: Messages

    /// The room after the user's message, and the message: it takes the next seq, with the members
    /// it mentions. Both are written together (`appendRoomMessage`); nil for an empty text.
    public func appendingUserMessage(_ text: String, now: Double) -> (room: AgentRoom, message: AgentRoomMessage)? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var room = self
        room.lastSeq += 1
        room.updatedAt = now
        let message = AgentRoomMessage(roomId: id, seq: room.lastSeq, at: now, author: .user, text: text,
                                       mentions: Self.mentions(in: text, members: members))
        return (room, message)
    }

    /// The members `text` mentions with `@` and their whole name, any case or accents, in the order
    /// they first appear (`resolveRoomMentions`): an `@` inside a word, or before a longer word, is no one.
    public static func mentions(in text: String, members: [Member]) -> [String] {
        func fold(_ value: String) -> [Character] {
            Array(value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased())
        }
        func isWord(_ character: Character?) -> Bool {
            guard let character else { return false }
            return character.isLetter || character.isNumber || character == "_"
        }
        let candidates = members.compactMap { member -> (id: String, name: [Character])? in
            guard let name = member.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
            return (member.agentId, fold(name))
        }.sorted { $0.name.count > $1.name.count }
        let folded = fold(text)
        var mentioned: [String] = []
        for at in folded.indices where folded[at] == "@" {
            if at > 0, isWord(folded[at - 1]) { continue }
            let start = at + 1
            let match = candidates.first { candidate in
                let end = start + candidate.name.count
                return end <= folded.count && Array(folded[start..<end]) == candidate.name && !isWord(end < folded.count ? folded[end] : nil)
            }
            if let match, !mentioned.contains(match.id) { mentioned.append(match.id) }
        }
        return mentioned
    }

    /// Who to suggest when the user writes without mentioning anyone (it reaches no one): the
    /// last agent who spoke.
    public static func lastAgentSpeaker(_ messages: [AgentRoomMessage]) -> String? {
        messages.sorted { $0.seq < $1.seq }.last { $0.author.agentId != nil }?.author.agentId
    }

    /// At most this many agent turns in a row without the user (`AGENT_ROOM_MAX_AGENT_TURNS`).
    public static let maxAgentTurns = 6

    /// The brake holds: the last `maxAgentTurns` messages are all agents'; the user writes to go on.
    public static func brakeHolds(_ messages: [AgentRoomMessage]) -> Bool {
        let last = messages.sorted { $0.seq < $1.seq }.suffix(maxAgentTurns)
        return last.count == maxAgentTurns && last.allSatisfy { $0.author.agentId != nil }
    }

    /// Members another agent mentioned that wait for the user ("Let It Answer"): agents can't wake
    /// them (Claude, unless allowed after the warning), and they haven't spoken, nor been mentioned
    /// by the user, since. Nothing waits in a paused or archived room.
    public func waitingForUser(seats: [AgentRoomSeat], messages: [AgentRoomMessage]) -> [String] {
        guard pausedAt == nil, archivedAt == nil else { return [] }
        let ordered = messages.sorted { $0.seq < $1.seq }
        return members.filter { member in
            guard member.wakeByAgents != true else { return false }
            let seat = seats.first { $0.agentId == member.agentId }
            guard seat?.inFlight == nil else { return false }
            let read = seat?.readThroughSeq ?? 0
            guard let mention = ordered.last(where: { $0.seq > read && $0.author.agentId != nil
                && $0.author.agentId != member.agentId && $0.mentions.contains(member.agentId) }) else { return false }
            return !ordered.contains { $0.seq > mention.seq
                && ($0.author.agentId == member.agentId || ($0.author == .user && $0.mentions.contains(member.agentId))) }
        }.map(\.agentId)
    }
}

/// One message of a room (`roommsg/<roomId>/<seq>`).
public struct AgentRoomMessage: Identifiable, Sendable, Equatable {
    public enum Author: Sendable, Equatable {
        case user
        /// Its name and emoji as they were when it wrote.
        case agent(id: String, name: String?, emoji: String?, sessionId: String?)

        public var agentId: String? {
            if case .agent(let id, _, _, _) = self { return id }
            return nil
        }

        public static func == (lhs: Author, rhs: Author) -> Bool {
            switch (lhs, rhs) {
            case (.user, .user): true
            case (.agent(let a, _, _, _), .agent(let b, _, _, _)): a == b
            default: false
            }
        }

        init?(json: JSONValue?) {
            switch json?["kind"]?.stringValue {
            case "user": self = .user
            case "agent":
                guard let id = json?["agentId"]?.stringValue, !id.isEmpty else { return nil }
                self = .agent(id: id, name: json?["name"]?.stringValue, emoji: json?["emoji"]?.stringValue,
                              sessionId: json?["sessionId"]?.stringValue)
            default: return nil
            }
        }

        var json: JSONValue {
            switch self {
            case .user: return ["kind": "user"]
            case .agent(let id, let name, let emoji, let sessionId):
                var object: [String: JSONValue] = ["kind": "agent", "agentId": .string(id)]
                if let name { object["name"] = .string(name) }
                if let emoji { object["emoji"] = .string(emoji) }
                if let sessionId { object["sessionId"] = .string(sessionId) }
                return .object(object)
            }
        }
    }

    public let roomId: String
    public let seq: Int
    public let at: Double
    public let author: Author
    public let text: String
    /// The members it mentions, in order.
    public let mentions: [String]
    /// An agent's message that mentions the user.
    public let mentionsUser: Bool
    var extra: [String: JSONValue] = [:]

    public var id: Int { seq }

    init(roomId: String, seq: Int, at: Double, author: Author, text: String, mentions: [String], mentionsUser: Bool = false) {
        self.roomId = roomId
        self.seq = seq
        self.at = at
        self.author = author
        self.text = text
        self.mentions = mentions
        self.mentionsUser = mentionsUser
    }

    init?(json: JSONValue) {
        guard json["v"]?.intValue == 1, let roomId = json["roomId"]?.stringValue, !roomId.isEmpty,
              let seq = json["seq"]?.intValue, seq >= 1, let author = Author(json: json["author"]),
              let text = json["text"]?.stringValue, !text.isEmpty else { return nil }
        self.init(roomId: roomId, seq: seq, at: json["at"]?.doubleValue ?? 0, author: author, text: text,
                  mentions: json["mentions"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                  mentionsUser: json["mentionsUser"]?.boolValue == true)
        let known: Set<String> = ["v", "roomId", "seq", "at", "author", "text", "mentions", "mentionsUser"]
        extra = (json.objectValue ?? [:]).filter { !known.contains($0.key) }
    }

    var json: JSONValue {
        var object = extra
        object["v"] = 1
        object["roomId"] = .string(roomId)
        object["seq"] = .number(Double(seq))
        object["at"] = .number(at)
        object["author"] = author.json
        object["text"] = .string(text)
        object["mentions"] = .array(mentions.map(JSONValue.string))
        if mentionsUser { object["mentionsUser"] = true }
        return .object(object)
    }

    public static let kvPrefix = "roommsg/"

    /// Zero-padded, so a key's order is its message's order.
    public static func kvKey(roomId: String, seq: Int) -> String {
        "\(kvPrefix)\(roomId)/\(String(format: "%010d", seq))"
    }

    func sealed(machineKey: Data) throws -> String {
        try AccountScopedBlob.seal(json, kind: .agentRoom, machineKey: machineKey)
    }

    static func open(_ base64: String, machineKey: Data) -> AgentRoomMessage? {
        AccountScopedBlob.open(base64, kind: .agentRoom, machineKey: machineKey).flatMap(AgentRoomMessage.init(json:))
    }
}

/// A member's thread in a room and its read marker (`roomseat/<roomId>/<agentId>`), written by the
/// daemon of its machine; the app only reads it.
public struct AgentRoomSeat: Identifiable, Sendable, Equatable {
    public struct InFlight: Sendable, Equatable {
        public let throughSeq: Int
        public let at: Double
    }

    public let roomId: String
    public let agentId: String
    public var sessionId: String?
    public var readThroughSeq: Int
    /// The turn its thread is working for the room.
    public var inFlight: InFlight?

    public var id: String { agentId }

    public init(roomId: String, agentId: String, sessionId: String? = nil, readThroughSeq: Int, inFlight: InFlight? = nil) {
        self.roomId = roomId
        self.agentId = agentId
        self.sessionId = sessionId
        self.readThroughSeq = readThroughSeq
        self.inFlight = inFlight
    }

    init?(json: JSONValue) {
        guard json["v"]?.intValue == 1, let roomId = json["roomId"]?.stringValue, !roomId.isEmpty,
              let agentId = json["agentId"]?.stringValue, !agentId.isEmpty else { return nil }
        let inFlight = json["inFlight"].flatMap { value -> InFlight? in
            guard let through = value["throughSeq"]?.intValue else { return nil }
            return InFlight(throughSeq: through, at: value["at"]?.doubleValue ?? 0)
        }
        self.init(roomId: roomId, agentId: agentId, sessionId: json["sessionId"]?.stringValue,
                  readThroughSeq: json["readThroughSeq"]?.intValue ?? 0, inFlight: inFlight)
    }

    public static let kvPrefix = "roomseat/"

    public static func kvPrefix(roomId: String) -> String { "\(kvPrefix)\(roomId)/" }

    public static func kvKey(roomId: String, agentId: String) -> String { kvPrefix(roomId: roomId) + agentId }

    static func open(_ base64: String, machineKey: Data) -> AgentRoomSeat? {
        AccountScopedBlob.open(base64, kind: .agentRoom, machineKey: machineKey).flatMap(AgentRoomSeat.init(json:))
    }
}

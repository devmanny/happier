import Foundation

/// Rooms in the account's UserKVStore (`AgentRoom`): the app writes the rooms and the user's
/// messages; each member's daemon delivers mentions and posts its replies and seats. Changes reach
/// the app through the account's KV changes (`applyRoomChange`) and the catch-up.
extension HappierStore {
    /// How many of a room's newest messages are read when it opens.
    static let roomWindow = 200

    public func room(id: String) -> AgentRoom? { rooms.first { $0.id == id } }

    /// The rooms that aren't archived, newest activity first.
    public var activeRooms: [AgentRoom] {
        rooms.filter { $0.archivedAt == nil }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func refreshRooms() async {
        guard let api, let machineKey = keys?.content.secretKey else { return }
        do {
            let listing = try await api.kvList(prefix: AgentRoom.kvPrefix)
            let items: [JSONValue] = listing["items"]?.arrayValue ?? []
            var read: [AgentRoom] = []
            for item in items {
                guard let key = item["key"]?.stringValue, let value = item["value"]?.stringValue, !value.isEmpty,
                      var room = AgentRoom.open(value, machineKey: machineKey), AgentRoom.kvKey(id: room.id) == key else { continue }
                room.version = item["version"]?.intValue ?? 0
                read.append(room)
            }
            if read != rooms { rooms = read }
            roomsError = nil
        } catch {
            roomsError = UserFacingError.message(for: error)
        }
    }

    /// A room's newest messages and its members' seats, read when it opens (and again after a catch-up).
    public func loadRoom(id: String) async {
        guard let api, let machineKey = keys?.content.secretKey, let room = room(id: id) else { return }
        do {
            let first = max(1, room.lastSeq - Self.roomWindow + 1)
            let have = Set((roomMessages[id] ?? []).map(\.seq))
            let missing = room.lastSeq >= first ? (first...room.lastSeq).filter { !have.contains($0) } : []
            let rows = missing.isEmpty ? [] : try await api.kvBulkGet(missing.map { AgentRoomMessage.kvKey(roomId: id, seq: $0) })
            let read = rows.compactMap { AgentRoomMessage.open($0.value, machineKey: machineKey) }.filter { $0.roomId == id }
            mergeRoomMessages(read, into: id)
            let listing = try await api.kvList(prefix: AgentRoomSeat.kvPrefix(roomId: id))
            let items: [JSONValue] = listing["items"]?.arrayValue ?? []
            var seats: [AgentRoomSeat] = []
            for item in items {
                if let value = item["value"]?.stringValue, let seat = AgentRoomSeat.open(value, machineKey: machineKey), seat.roomId == id {
                    seats.append(seat)
                }
            }
            roomSeats[id] = seats
        } catch {
            report(error)
        }
    }

    private func mergeRoomMessages(_ messages: [AgentRoomMessage], into roomId: String) {
        var bySeq = Dictionary((roomMessages[roomId] ?? []).map { ($0.seq, $0) }, uniquingKeysWith: { $1 })
        for message in messages { bySeq[message.seq] = message }
        let merged = bySeq.values.sorted { $0.seq < $1.seq }
        if merged != roomMessages[roomId] { roomMessages[roomId] = merged }
    }

    private func storeRoom(_ room: AgentRoom) {
        if let index = rooms.firstIndex(where: { $0.id == room.id }) {
            if rooms[index].version > room.version { return }
            rooms[index] = room
        } else {
            rooms.append(room)
        }
    }

    /// Stores a new room.
    @discardableResult
    public func createRoom(_ room: AgentRoom) async -> AgentRoom? {
        guard let api, let machineKey = keys?.content.secretKey else { return nil }
        do {
            switch try await api.kvWrite(key: AgentRoom.kvKey(id: room.id), value: try room.sealed(machineKey: machineKey), version: -1) {
            case .saved(let version):
                var saved = room
                saved.version = version
                storeRoom(saved)
                roomMessages[room.id] = []
                roomSeats[room.id] = []
                return saved
            case .conflict:
                throw RPCError(message: String(localized: "A room with this id already exists."), code: "version-mismatch")
            }
        } catch {
            report(error)
            return nil
        }
    }

    /// The user's message: the room (at its version) and the message (new) are written together, so
    /// it takes the next seq; when an agent wrote first it goes again on the newer room. Quoting a
    /// message (Reply) answers it and reaches its author (`AgentRoom.replying`). False after
    /// reporting why not.
    @discardableResult
    public func sendRoomMessage(roomId: String, text: String, replyingTo quoted: AgentRoomMessage? = nil) async -> Bool {
        await appendRoomMessage(roomId: roomId) { room, now in
            if let quoted { return room.replying(to: quoted, with: text, now: now) }
            return room.appendingUserMessage(text, now: now)
        }
    }

    /// The user dismissed a member's "Let It Answer" for the mention at `mentionSeq`: stored in the
    /// room, so no device shows it until another agent mentions that member again.
    @discardableResult
    public func dismissRoomWait(roomId: String, agentId: String, mentionSeq: Int) async -> AgentRoom? {
        await updateRoom(id: roomId) { room in room.dismissWait(agentId: agentId, mentionSeq: mentionSeq) }
    }

    /// An `<options>` option the user picked on an agent's message: answers only that agent.
    @discardableResult
    public func answerRoomOption(roomId: String, message: AgentRoomMessage, option: String) async -> Bool {
        await appendRoomMessage(roomId: roomId) { room, now in room.answering(message, with: option, now: now) }
    }

    /// Writes the user's next message (`make` on the latest room) and the room together, again on a
    /// newer room after a conflict. Done (true) once both are saved; the room is read again after.
    private func appendRoomMessage(roomId: String,
                                   _ make: (AgentRoom, Double) -> (room: AgentRoom, message: AgentRoomMessage)?) async -> Bool {
        guard let api, let machineKey = keys?.content.secretKey, var base = room(id: roomId) else { return false }
        let roomKey = AgentRoom.kvKey(id: roomId)
        do {
            for _ in 0..<4 {
                guard let (room, message) = make(base, ServerClock.nowMs()) else { return false }
                let messageKey = AgentRoomMessage.kvKey(roomId: roomId, seq: message.seq)
                switch try await api.kvMutate([(roomKey, try room.sealed(machineKey: machineKey), base.version),
                                               (messageKey, try message.sealed(machineKey: machineKey), -1)]) {
                case .saved(let versions):
                    var saved = room
                    saved.version = versions[roomKey] ?? base.version + 1
                    storeRoom(saved)
                    if roomMessages[roomId] != nil {
                        mergeRoomMessages([message], into: roomId)
                        // Whatever others wrote before it (the conflict's messages) is read behind the
                        // send: the message is saved, so the composer is done with it.
                        Task { await self.loadRoom(id: roomId) }
                    }
                    return true
                case .conflict(let conflicts):
                    if let current = conflicts[roomKey], let value = current.value, var latest = AgentRoom.open(value, machineKey: machineKey) {
                        latest.version = current.version
                        base = latest
                    } else {
                        await refreshRooms()
                        guard let latest = self.room(id: roomId), latest.version != base.version else { break }
                        base = latest
                    }
                }
            }
            throw RPCError(message: String(localized: "The room kept changing. Try again."), code: "version-mismatch")
        } catch {
            report(error)
            return false
        }
    }

    /// Rewrites the room with `change` at its version, applying it again on a newer copy.
    @discardableResult
    public func updateRoom(id: String, _ change: @escaping (inout AgentRoom) -> Void) async -> AgentRoom? {
        guard let api, let machineKey = keys?.content.secretKey, var base = room(id: id) else { return nil }
        do {
            for _ in 0..<4 {
                var next = base
                change(&next)
                next.updatedAt = max(next.updatedAt, ServerClock.nowMs())
                switch try await api.kvWrite(key: AgentRoom.kvKey(id: id), value: try next.sealed(machineKey: machineKey), version: base.version) {
                case .saved(let version):
                    next.version = version
                    storeRoom(next)
                    return next
                case .conflict(let version, let value):
                    guard let value, var latest = AgentRoom.open(value, machineKey: machineKey) else {
                        throw RPCError(message: String(localized: "This room was deleted somewhere else."), code: "version-mismatch")
                    }
                    latest.version = version
                    base = latest
                }
            }
            throw RPCError(message: String(localized: "The room kept changing. Try again."), code: "version-mismatch")
        } catch {
            report(error)
            return nil
        }
    }

    /// The pause button: nothing is delivered while paused; turns already running finish.
    @discardableResult
    public func setRoomPaused(id: String, _ paused: Bool) async -> AgentRoom? {
        await updateRoom(id: id) { room in room.pausedAt = paused ? (room.pausedAt ?? ServerClock.nowMs()) : nil }
    }

    /// A member's "Answers other agents" in a room already made (the room's info). Turning it on for
    /// Claude follows the Consumer Terms warning, which the caller shows first.
    @discardableResult
    public func setRoomMemberAnswersAgents(roomId: String, agentId: String, _ on: Bool) async -> AgentRoom? {
        await updateRoom(id: roomId) { room in
            guard let index = room.members.firstIndex(where: { $0.agentId == agentId }) else { return }
            room.members[index].wakeByAgents = on
        }
    }

    /// How the agents call the user in the room (and mention them); empty clears it ("User").
    @discardableResult
    public func setRoomUserName(roomId: String, _ name: String) async -> AgentRoom? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return await updateRoom(id: roomId) { room in room.userName = name.isEmpty ? nil : name }
    }

    /// "Let It Answer": the user's message that mentions the member, which wakes it like any of theirs.
    @discardableResult
    public func letRoomMemberAnswer(roomId: String, agentId: String) async -> Bool {
        guard let member = room(id: roomId)?.members.first(where: { $0.agentId == agentId }) else { return false }
        let name = member.name ?? agentId
        return await sendRoomMessage(roomId: roomId, text: String(localized: "@\(name), go ahead."))
    }

    /// One changed `room/`, `roommsg/` or `roomseat/` row applied to what is loaded; false for other keys.
    func applyRoomChange(_ change: AccountKVSync.Change, machineKey: Data) -> Bool {
        if change.key.hasPrefix(AgentRoom.kvPrefix) {
            let id = String(change.key.dropFirst(AgentRoom.kvPrefix.count))
            if let current = room(id: id), current.version >= change.version { return true }
            if let value = change.value, var room = AgentRoom.open(value, machineKey: machineKey), room.id == id {
                room.version = change.version
                storeRoom(room)
                // A message whose own change hasn't arrived (or got lost) is read with the room.
                if let loaded = roomMessages[id], room.lastSeq > (loaded.last?.seq ?? 0) {
                    Task { await self.loadRoom(id: id) }
                }
            } else {
                rooms.removeAll { $0.id == id }
            }
            return true
        }
        if change.key.hasPrefix(AgentRoomMessage.kvPrefix) {
            let roomId = change.key.dropFirst(AgentRoomMessage.kvPrefix.count).split(separator: "/").first.map(String.init) ?? ""
            if roomMessages[roomId] != nil, let value = change.value, let message = AgentRoomMessage.open(value, machineKey: machineKey),
               message.roomId == roomId {
                mergeRoomMessages([message], into: roomId)
            }
            return true
        }
        if change.key.hasPrefix(AgentRoomSeat.kvPrefix) {
            let parts = change.key.dropFirst(AgentRoomSeat.kvPrefix.count).split(separator: "/").map(String.init)
            guard parts.count == 2, var seats = roomSeats[parts[0]] else { return true }
            seats.removeAll { $0.agentId == parts[1] }
            if let value = change.value, let seat = AgentRoomSeat.open(value, machineKey: machineKey), seat.roomId == parts[0] {
                seats.append(seat)
            }
            roomSeats[parts[0]] = seats
            return true
        }
        return false
    }
}

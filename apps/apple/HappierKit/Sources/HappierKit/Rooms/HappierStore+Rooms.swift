import Foundation

/// Rooms in the account's UserKVStore (`AgentRoom`): the app writes the rooms and the user's
/// messages (and edits, cancels or sends now one its agent doesn't have yet, `reviseQueuedRoomMessage`); each
/// member's daemon delivers mentions and posts its replies and seats. Changes reach the app through
/// the account's KV changes (`applyRoomChange`) and the catch-up.
extension HappierStore {
    /// How many of a room's newest messages are read when it opens.
    static let roomWindow = 200

    public func room(id: String) -> AgentRoom? { rooms.first { $0.id == id } }

    /// The group rooms that aren't archived, newest activity first (the agents' chats open from their circles).
    public var activeRooms: [AgentRoom] {
        rooms.filter { $0.archivedAt == nil && !$0.isDirect }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The agent's chat with the user, once it has one.
    public func directRoom(agentId: String) -> AgentRoom? {
        room(id: AgentRoom.directId(agentId: agentId))
    }

    /// The agent's chat, made the first time (working in `directory` on `machineId`, under the name
    /// the user goes by in their rooms). Another device may have made it: the rooms are read again
    /// before making one, and a write that finds it already there reads it instead.
    public func openDirectRoom(with agent: AgentProfile, machineId: String, directory: String) async -> AgentRoom? {
        if directRoom(agentId: agent.id) == nil { await refreshRooms() }
        if let room = directRoom(agentId: agent.id) {
            // Nothing written yet, so no thread of the agent's lives where it was made: it moves.
            guard room.lastSeq == 0, let member = room.members.first, member.machineId != machineId || member.directory != directory else { return room }
            return await updateRoom(id: room.id) { room in
                guard room.lastSeq == 0, !room.members.isEmpty else { return }
                room.members[0].machineId = machineId
                room.members[0].directory = directory
            } ?? room
        }
        let userName = rooms.filter { $0.archivedAt == nil }.max { $0.updatedAt < $1.updatedAt }?.userName
        if let made = await createRoom(AgentRoom.direct(with: agent, machineId: machineId, directory: directory, userName: userName)) {
            return made
        }
        await refreshRooms()
        return directRoom(agentId: agent.id)
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
            // Every room's seats, once: which session is whose thread, without opening the room.
            let seatListing = try await api.kvList(prefix: AgentRoomSeat.kvPrefix)
            var seats = Dictionary(read.map { ($0.id, [AgentRoomSeat]()) }, uniquingKeysWith: { first, _ in first })
            for item in seatListing["items"]?.arrayValue ?? [] {
                guard let seat = Self.seat(listed: item, machineKey: machineKey), seats[seat.roomId] != nil else { continue }
                seats[seat.roomId]?.append(seat)
            }
            for (roomId, listed) in seats { storeSeats(listed, roomId: roomId) }
            roomsError = nil
        } catch {
            roomsError = UserFacingError.message(for: error)
        }
    }

    /// Every member's thread in the rooms that aren't archived, by session id (from the seats,
    /// read with the rooms): where its replies are read (the agent's chat, or the group room) and
    /// whether its turn for the room is under way. The agents' circles read them (`AgentRoster`).
    public var roomThreads: [String: AgentRoomThread] {
        var threads: [String: AgentRoomThread] = [:]
        for room in rooms where room.archivedAt == nil {
            for seat in roomSeats[room.id] ?? [] {
                guard let sessionId = seat.sessionId else { continue }
                threads[sessionId] = AgentRoomThread(selection: room.selection, inFlight: seat.inFlight != nil)
            }
        }
        return threads
    }

    /// The room's threads with a reply you haven't read (the server's `unreadSince`).
    public func unreadRoomThreads(roomId: String) -> [String] {
        (roomSeats[roomId] ?? []).compactMap(\.sessionId).filter { sessions[$0]?.unreadSince != nil }
    }

    /// Reading a room reads its threads: what its members wrote there is what their threads
    /// replied, so the session list, the agents' circles and every device stop counting it as
    /// unread. The same rule as an open session's (`markRead`), for every room.
    public func readRoomThreads(roomId: String) {
        for sessionId in unreadRoomThreads(roomId: roomId) { markRead(sessionId) }
    }

    /// A room's newest messages and its members' seats, read when it opens (and again after a
    /// catch-up). Every room's seats also come with the rooms (`refreshRooms`). The user's messages
    /// that may have been edited or canceled since they were read here (`AgentRoom.queued`) are read
    /// again, and dropped when gone: the seats are read first, so what is read after them past what
    /// the agent had then is known not to change any more (`roomSettledThroughSeq`).
    public func loadRoom(id: String) async {
        guard let api, let machineKey = keys?.content.secretKey, let room = room(id: id) else { return }
        do {
            let listing = try await api.kvList(prefix: AgentRoomSeat.kvPrefix(roomId: id))
            let seats = (listing["items"]?.arrayValue ?? []).compactMap { Self.seat(listed: $0, machineKey: machineKey) }
                .filter { $0.roomId == id }
            let settled = room.settledThroughSeq(seats: seats)
            let held = roomMessages[id] ?? []
            let first = max(1, room.lastSeq - Self.roomWindow + 1)
            let have = Set(held.map(\.seq))
            let missing = room.lastSeq >= first ? (first...room.lastSeq).filter { !have.contains($0) } : []
            let unsettled = held.filter { $0.author == .user && $0.seq > (roomSettledThroughSeq[id] ?? 0) }.map(\.seq)
            let asked = missing + unsettled
            let rows = asked.isEmpty ? [] : try await api.kvBulkGet(asked.map { AgentRoomMessage.kvKey(roomId: id, seq: $0) })
            let read = rows.compactMap { row -> AgentRoomMessage? in
                guard var message = AgentRoomMessage.open(row.value, machineKey: machineKey), message.roomId == id else { return nil }
                message.version = row.version
                return message
            }
            mergeRoomMessages(read, removing: Set(unsettled).subtracting(read.map(\.seq)), into: id)
            storeSeats(seats, roomId: id)
            roomSettledThroughSeq[id] = max(roomSettledThroughSeq[id] ?? 0, settled)
        } catch {
            report(error)
        }
    }

    /// A seat from a listing, at its version; nil for a row that isn't one or is stored under another key.
    private static func seat(listed item: JSONValue, machineKey: Data) -> AgentRoomSeat? {
        guard let key = item["key"]?.stringValue, let value = item["value"]?.stringValue,
              var seat = AgentRoomSeat.open(value, machineKey: machineKey),
              AgentRoomSeat.kvKey(roomId: seat.roomId, agentId: seat.agentId) == key else { return nil }
        seat.version = item["version"]?.intValue ?? 0
        return seat
    }

    /// Adds `messages` (a copy older than the one held is ignored) and drops the seqs `removing`,
    /// for good: a seq is never used again, so a copy read before it went never comes back.
    private func mergeRoomMessages(_ messages: [AgentRoomMessage], removing gone: Set<Int> = [], into roomId: String) {
        if !gone.isEmpty { roomRemovedSeqs[roomId, default: []].formUnion(gone) }
        let removed = roomRemovedSeqs[roomId] ?? []
        var bySeq = Dictionary((roomMessages[roomId] ?? []).map { ($0.seq, $0) }, uniquingKeysWith: { $1 })
        for seq in gone { bySeq[seq] = nil }
        for message in messages where !removed.contains(message.seq) && (bySeq[message.seq]?.version ?? -1) <= message.version {
            bySeq[message.seq] = message
        }
        let merged = bySeq.values.sorted { $0.seq < $1.seq }
        if merged != roomMessages[roomId] { roomMessages[roomId] = merged }
    }

    /// Seats read (a listing, or the one a write returned) kept with those held: per member the
    /// newer version wins, and a held seat they lack stays. Seats are never deleted, and one written
    /// after a listing was read arrives as a change (`applyRoomChange`), newer than the listing.
    private func storeSeats(_ seats: [AgentRoomSeat], roomId: String) {
        var merged = roomSeats[roomId] ?? []
        for seat in seats {
            if let index = merged.firstIndex(where: { $0.agentId == seat.agentId }) {
                if merged[index].version < seat.version { merged[index] = seat }
            } else {
                merged.append(seat)
            }
        }
        if roomSeats[roomId] != merged { roomSeats[roomId] = merged }
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
                // An agent's chat another device just made is no error: it is read instead (`openDirectRoom`).
                if room.isDirect { return nil }
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
                        var message = message
                        message.version = versions[messageKey] ?? 0
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

    /// A change to the user's message that waits for the agent in its chat (`reviseQueuedRoomMessage`).
    public enum QueuedChange: Equatable, Sendable {
        /// Its text instead (trimmed; an empty one changes nothing).
        case edit(String)
        /// Withdrawn: the agent never gets it.
        case cancel
        /// Steer Now: it reaches the agent in its running turn, with the messages waiting before it
        /// (`AgentRoomMessage.sendNow`).
        case sendNow
    }

    /// What became of a change to a message waiting for its agent (`reviseQueuedRoomMessage`).
    public enum QueuedRevision: Equatable, Sendable {
        case done
        /// Too late: the agent already has it; nothing was changed.
        case alreadyDelivered
        /// Nothing was changed; why was reported.
        case failed
    }

    /// Edits, cancels or sends now (`change`) the user's message that waits for the agent in its chat
    /// (`AgentRoom.queued`). One atomic write rewrites (or deletes) the message at its version and
    /// writes the agent's seat back exactly as it was read, at its version: the seat only guards the
    /// write, its content stays the daemon's. The daemon reads the seat, then the messages, and takes
    /// a delivery (or a steer into the running turn) by writing that seat at the version it read, so
    /// either this write wins (that delivery fails and is read again, with the change) or it fails
    /// and the seat it returns says whether the agent already has the message. A seat that moved
    /// without taking it is tried again. A message already sent now is done without a write.
    public func reviseQueuedRoomMessage(roomId: String, seq: Int, _ change: QueuedChange) async -> QueuedRevision {
        guard let api, let machineKey = keys?.content.secretKey, let agentId = room(id: roomId)?.directAgentId,
              var message = roomMessages[roomId]?.first(where: { $0.seq == seq }), message.author == .user else { return .failed }
        var seat = roomSeats[roomId]?.first { $0.agentId == agentId }
        let messageKey = AgentRoomMessage.kvKey(roomId: roomId, seq: seq)
        let seatKey = AgentRoomSeat.kvKey(roomId: roomId, agentId: agentId)
        do {
            for _ in 0..<4 {
                // Before its first delivery the agent has no seat: nothing could guard the change.
                guard let current = seat, let unchanged = current.sealed else {
                    throw RPCError(message: String(localized: "This message is on its way and can't be changed now."), code: "version-mismatch")
                }
                if seq <= current.deliveredThroughSeq {
                    storeSeats([current], roomId: roomId)
                    return .alreadyDelivered
                }
                // The message as it is written; nil deletes it.
                let revised: AgentRoomMessage?
                switch change {
                case .edit(let text):
                    guard let edited = message.editing(text) else { return .failed }
                    revised = edited
                case .cancel:
                    revised = nil
                case .sendNow:
                    // Sent now already, here or on another device.
                    if message.sendNow { return .done }
                    revised = message.sendingNow()
                }
                switch try await api.kvMutate([(messageKey, try revised?.sealed(machineKey: machineKey), message.version),
                                               (seatKey, unchanged, current.version)]) {
                case .saved(let versions):
                    var guarded = current
                    guarded.version = versions[seatKey] ?? current.version + 1
                    storeSeats([guarded], roomId: roomId)
                    if var revised {
                        revised.version = versions[messageKey] ?? message.version + 1
                        mergeRoomMessages([revised], into: roomId)
                    } else {
                        mergeRoomMessages([], removing: [seq], into: roomId)
                    }
                    return .done
                case .conflict(let conflicts):
                    if let moved = conflicts[seatKey] {
                        guard let value = moved.value, var latest = AgentRoomSeat.open(value, machineKey: machineKey) else {
                            throw RPCError(message: String(localized: "This chat changed somewhere else. Try again."), code: "version-mismatch")
                        }
                        latest.version = moved.version
                        seat = latest
                    }
                    if let changed = conflicts[messageKey] {
                        guard let value = changed.value, var latest = AgentRoomMessage.open(value, machineKey: machineKey) else {
                            // Canceled on another device meanwhile.
                            mergeRoomMessages([], removing: [seq], into: roomId)
                            if change == .cancel { return .done }
                            throw RPCError(message: String(localized: "This message was canceled on another device."), code: "version-mismatch")
                        }
                        latest.version = changed.version
                        message = latest
                        mergeRoomMessages([latest], into: roomId)
                    }
                }
            }
            throw RPCError(message: String(localized: "The chat kept changing. Try again."), code: "version-mismatch")
        } catch {
            report(error)
            return .failed
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

    /// One changed `room/`, `roommsg/` or `roomseat/` row applied to what is loaded (a seat to any
    /// known room): a deleted message (canceled before its agent had it) leaves, and a message or
    /// seat older than the one held changes nothing. False for other keys.
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
            let parts = change.key.dropFirst(AgentRoomMessage.kvPrefix.count).split(separator: "/").map(String.init)
            guard parts.count == 2, let seq = Int(parts[1]) else { return true }
            guard let held = roomMessages[parts[0]] else {
                // Not read yet, maybe being read now: remember the cancel so that read leaves it out.
                // `roomMessages` stays unset, since a set entry means the chat has been read.
                if change.value == nil { roomRemovedSeqs[parts[0], default: []].insert(seq) }
                return true
            }
            if let value = change.value {
                if var message = AgentRoomMessage.open(value, machineKey: machineKey), message.roomId == parts[0], message.seq == seq {
                    message.version = change.version
                    mergeRoomMessages([message], into: parts[0])
                }
            } else if (held.first { $0.seq == seq }?.version ?? -1) < change.version {
                // Canceled before its agent had it (`reviseQueuedRoomMessage`, on any device); one not
                // held yet may be on its way in a read.
                mergeRoomMessages([], removing: [seq], into: parts[0])
            }
            return true
        }
        if change.key.hasPrefix(AgentRoomSeat.kvPrefix) {
            let parts = change.key.dropFirst(AgentRoomSeat.kvPrefix.count).split(separator: "/").map(String.init)
            guard parts.count == 2, roomSeats[parts[0]] != nil || room(id: parts[0]) != nil else { return true }
            var seats = roomSeats[parts[0]] ?? []
            // An echo of a write older than the seat held changes nothing.
            if let held = seats.first(where: { $0.agentId == parts[1] }), held.version >= change.version { return true }
            seats.removeAll { $0.agentId == parts[1] }
            if let value = change.value, var seat = AgentRoomSeat.open(value, machineKey: machineKey), seat.roomId == parts[0] {
                seat.version = change.version
                seats.append(seat)
            }
            roomSeats[parts[0]] = seats
            return true
        }
        return false
    }
}

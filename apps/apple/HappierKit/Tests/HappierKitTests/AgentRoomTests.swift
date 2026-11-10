import Foundation
import Testing
@testable import HappierKit

/// Rooms (`packages/protocol/src/rooms/agentRoom.ts`): sealed `agent_room` rows under `room/`,
/// `roommsg/<id>/<seq>` and `roomseat/<id>/<agent>`; what the app writes and how it reads a room.
@Suite struct AgentRoomTests {
    static let machineKey = Data((0..<32).map { UInt8($0) })

    static func room(_ overrides: [String: JSONValue] = [:]) -> AgentRoom {
        var json: [String: JSONValue] = [
            "v": 1, "id": "r1", "title": "App nueva", "userName": "Manny", "lastSeq": 0, "createdAt": 1, "updatedAt": 1,
            "members": [
                ["agentId": "a-mateo", "name": "Mateo", "emoji": "🛠️", "machineId": "m1", "directory": "/app-movil", "wakeByAgents": true],
                ["agentId": "a-tomas", "name": "Tomás", "machineId": "m2", "directory": "/app-escritorio"],
            ],
        ]
        for (key, value) in overrides { json[key] = value }
        return AgentRoom(json: .object(json))!
    }

    static func message(_ seq: Int, by author: JSONValue, mentions: [String] = [], text: String = "hola") -> AgentRoomMessage {
        AgentRoomMessage(json: ["v": 1, "roomId": "r1", "seq": .number(Double(seq)), "at": .number(Double(seq)), "author": author,
                                "text": .string(text), "mentions": .array(mentions.map(JSONValue.string))])!
    }

    static let user: JSONValue = ["kind": "user"]
    static func agent(_ id: String) -> JSONValue { ["kind": "agent", "agentId": .string(id)] }

    @Test func keysAreOpaqueAndMessagesSortByTheirKey() {
        #expect(AgentRoom.kvKey(id: "r1") == "room/r1")
        #expect(AgentRoomSeat.kvKey(roomId: "r1", agentId: "a-mateo") == "roomseat/r1/a-mateo")
        let keys = [100, 9, 10].map { AgentRoomMessage.kvKey(roomId: "r1", seq: $0) }
        #expect(keys.sorted() == [AgentRoomMessage.kvKey(roomId: "r1", seq: 9), AgentRoomMessage.kvKey(roomId: "r1", seq: 10),
                                  AgentRoomMessage.kvKey(roomId: "r1", seq: 100)])
        #expect(AgentRoomMessage.kvKey(roomId: "r1", seq: 9) == "roommsg/r1/0000000009")
    }

    @Test func aRoomSealsUnderItsKindAndKeepsWhatANewerBuildWrote() throws {
        let room = Self.room(["futureField": ["x": 1]])
        let sealed = try room.sealed(machineKey: Self.machineKey)
        #expect(AccountScopedBlob.open(sealed, kind: .agentTask, machineKey: Self.machineKey) == nil)
        let opened = try #require(AgentRoom.open(sealed, machineKey: Self.machineKey))
        #expect(opened.members.map(\.agentId) == ["a-mateo", "a-tomas"])
        #expect(opened.members.first?.wakeByAgents == true)
        #expect(opened.json["futureField"] == ["x": 1])
        var untitled = Self.room().json.objectValue!
        untitled["title"] = " "
        #expect(AgentRoom(json: .object(untitled)) == nil)
    }

    @Test func mentionsAreTheWholeNamesWithAtInOrderOnceEachAnyCaseOrAccent() {
        let members = [("a-mateo", "Mateo"), ("a-tomas", "Tomás"), ("a-leo", "Leo"), ("a-leonardo", "Leonardo"),
                       ("a-nomada", "Claude Nómada")].map { AgentRoom.Member(agentId: $0.0, name: $0.1, machineId: "m", directory: "/") }
            + [AgentRoom.Member(agentId: "a-unnamed", name: nil, machineId: "m", directory: "/")]
        #expect(AgentRoom.mentions(in: "@tomas mira esto y luego @Mateo; gracias @TOMÁS", members: members) == ["a-tomas", "a-mateo"])
        #expect(AgentRoom.mentions(in: "@Leonardo y @claude nómada", members: members) == ["a-leonardo", "a-nomada"])
        #expect(AgentRoom.mentions(in: "@Leo, ¿y tú?", members: members) == ["a-leo"])
        #expect(AgentRoom.mentions(in: "escríbele a manny@mateo.dev o a @Mateo2", members: members) == [])
    }

    @Test func theUsersMessageTakesTheNextSeqWithItsMentions() throws {
        let (room, message) = try #require(Self.room(["lastSeq": 4]).appendingUserMessage("  @Tomás revisa esto  ", now: 50))
        #expect(room.lastSeq == 5)
        #expect(room.updatedAt == 50)
        #expect(message.seq == 5)
        #expect(message.author == .user)
        #expect(message.text == "@Tomás revisa esto")
        #expect(message.mentions == ["a-tomas"])
        #expect(message.json["mentionsUser"] == nil)
        #expect(Self.room().appendingUserMessage("   ", now: 1) == nil)
    }

    @Test func withoutAMentionTheLastAgentWhoSpokeIsSuggested() {
        let messages = [Self.message(1, by: Self.user, mentions: ["a-tomas"]), Self.message(2, by: Self.agent("a-tomas")),
                        Self.message(3, by: Self.agent("a-mateo")), Self.message(4, by: Self.user)]
        #expect(AgentRoom.lastAgentSpeaker(messages) == "a-mateo")
        #expect(AgentRoom.lastAgentSpeaker([Self.message(1, by: Self.user)]) == nil)
    }

    @Test func aMemberAnotherAgentMentionedWaitsForTheUserUnlessAgentsMayWakeIt() {
        // Mateo (woken by agents) mentions Tomás (not woken by agents): Tomás waits for "Let It Answer".
        let room = Self.room(["lastSeq": 3])
        let messages = [Self.message(1, by: Self.user, mentions: ["a-mateo"]), Self.message(2, by: Self.agent("a-mateo"), mentions: ["a-tomas"]),
                        Self.message(3, by: Self.agent("a-tomas"), mentions: ["a-mateo"])]
        let seats = [AgentRoomSeat(roomId: "r1", agentId: "a-tomas", readThroughSeq: 1), AgentRoomSeat(roomId: "r1", agentId: "a-mateo", readThroughSeq: 2)]
        // Tomás wrote #3 after #2, so it already answered: nobody waits.
        #expect(room.waitingForUser(seats: seats, messages: messages).isEmpty)
        let unanswered = Array(messages.prefix(2))
        #expect(Self.room(["lastSeq": 2]).waitingForUser(seats: seats, messages: unanswered) == ["a-tomas"])
        // The user's own mention wakes anyone, and a paused room waits for the user to resume, not answer.
        #expect(Self.room(["lastSeq": 2, "pausedAt": 9]).waitingForUser(seats: seats, messages: unanswered).isEmpty)
    }

    @Test func theBrakeHoldsAfterSixAgentTurnsInARowWithoutTheUser() {
        let agents = (2...7).map { Self.message($0, by: Self.agent($0.isMultiple(of: 2) ? "a-mateo" : "a-tomas")) }
        #expect(AgentRoom.brakeHolds([Self.message(1, by: Self.user)] + agents))
        #expect(!AgentRoom.brakeHolds([Self.message(1, by: Self.user)] + agents.dropLast()))
        #expect(!AgentRoom.brakeHolds(agents + [Self.message(8, by: Self.user)]))
    }

    @Test func theSidebarSelectsARoomLikeASessionButNeverReadsItAsOne() {
        let selection = AgentRoom.selection(id: "r1")
        #expect(AgentRoom.id(inSelection: selection) == "r1")
        #expect(AgentRoom.id(inSelection: AgentProfile.selection(id: "r1")) == nil)
        #expect(AgentProfile.id(inSelection: selection) == nil)
        #expect(AgentRoom.id(inSelection: "cmuenhmmr0isvpe01pzj907ri") == nil)
    }
}

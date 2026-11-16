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

    @Test func atTodosOrAtAllMentionsEveryMemberAsTheProtocolDoes() {
        let members = Self.room().members
        let everyone = members.map(\.agentId)
        #expect(AgentRoom.mentions(in: "@todos ¿cómo van?", members: members) == everyone)
        #expect(AgentRoom.mentions(in: "hola @ALL", members: members) == everyone)
        #expect(AgentRoom.mentions(in: "@Tódos", members: members) == everyone)
        #expect(AgentRoom.mentions(in: "@Tomás primero y luego @todos", members: members) == ["a-tomas", "a-mateo"])
        #expect(AgentRoom.mentions(in: "escribe a todos@all.com, @allison o @todosbien", members: members) == [])
    }

    @Test func suggestionsOfferEveryoneFirstThenTheMembersTheTypedWordStarts() {
        let members = Self.room().members
        #expect(AgentRoom.mentionSuggestions(for: "", members: members) == [.everyone, .member("a-mateo"), .member("a-tomas")])
        #expect(AgentRoom.mentionSuggestions(for: "to", members: members) == [.everyone, .member("a-tomas")])
        #expect(AgentRoom.mentionSuggestions(for: "AL", members: members) == [.everyone])
        #expect(AgentRoom.mentionSuggestions(for: "ma", members: members) == [.member("a-mateo")])
        // A whole name already typed needs no chip.
        #expect(AgentRoom.mentionSuggestions(for: "Mateo", members: members) == [])
        #expect(AgentRoom.MentionSuggestion.everyone.label(members: members) == "@todos")
    }

    @Test func theMentionsInAMessageAreFoundToHighlightThem() {
        let text = "Hola @tomás, y luego @todos (no manny@mateo.dev)"
        let ranges = AgentRoom.mentionRanges(in: text, members: Self.room().members)
        #expect(ranges.map { String(text[$0]) } == ["@tomás", "@todos"])
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

    @Test func pickingAnOptionAnswersOnlyItsAuthorAndSaysWhichMessageItAnswers() throws {
        let tomas: JSONValue = ["kind": "agent", "agentId": "a-tomas", "name": "Tomás"]
        let asked = Self.message(4, by: tomas, text: "¿Cuál sigue?")
        // Even an option that says @todos reaches only the agent that offered it.
        let (room, answer) = try #require(Self.room(["lastSeq": 4]).answering(asked, with: "Avisa a @todos", now: 9))
        #expect(room.lastSeq == 5)
        #expect(answer.text == "@Tomás Avisa a @todos")
        #expect(answer.mentions == ["a-tomas"])
        #expect(answer.replyTo == 4)
        #expect(answer.json["replyTo"] == ["seq": 4])
        #expect(AgentRoomMessage(json: answer.json)?.replyTo == 4)

        // The option picked on a message is the one its answer carries; the others are done.
        let options = ["Retomar GasCorp", "Avisa a @todos"]
        #expect(AgentRoom.chosenOption(on: asked, options: options, messages: [asked, answer]) == "Avisa a @todos")
        #expect(AgentRoom.chosenOption(on: asked, options: options, messages: [asked]) == nil)
    }

    @Test func anInvitedAgentAnswersOtherAgentsUnlessItIsClaude() {
        // Codex or Kimi are woken by other agents from the start; Claude only past the 3.7 warning.
        #expect(AgentRoom.Member.answersAgentsByDefault(providerId: "codex"))
        #expect(AgentRoom.Member.answersAgentsByDefault(providerId: "kimi"))
        #expect(!AgentRoom.Member.answersAgentsByDefault(providerId: "claude"))
        let mateo = AgentProfile(id: "a-mateo", name: "Mateo", emoji: "🤖", providerId: "codex", account: .init(label: "ChatGPT"))
        let invited = AgentRoom.Member(mateo, machineId: "m1", directory: "/p")
        #expect(invited.wakeByAgents == true)
        #expect(invited.json["wakeByAgents"] == true)
    }

    @Test func aNewMemberWorksInItsAgentsLatestFolderOnThatMachineElseTheHome() throws {
        func session(_ id: String, agent: String?, machine: String, path: String, at: Double) throws -> Session {
            var metadata: [String: JSONValue] = ["path": .string(path), "machineId": .string(machine)]
            if let agent { metadata["agentIdentityV1"] = ["v": 1, "id": .string(agent), "name": "x"] }
            return try Session(row: ["id": .string(id), "seq": 1, "createdAt": 1, "updatedAt": .number(at), "active": false, "encryptionMode": "plain",
                                     "metadata": .string(String(decoding: try JSONValue.object(metadata).encoded(), as: UTF8.self)), "metadataVersion": 1],
                               keys: nil)
        }
        let sessions = [try session("a", agent: "a-mateo", machine: "m1", path: "/p/movil", at: 10),
                        try session("b", agent: "a-mateo", machine: "m1", path: "/p/radar", at: 30),
                        try session("c", agent: "a-mateo", machine: "m2", path: "/p/otra", at: 50),
                        try session("d", agent: "a-tomas", machine: "m1", path: "/p/escritorio", at: 40),
                        try session("e", agent: nil, machine: "m1", path: "/p/sin-agente", at: 60)]
        #expect(AgentRoom.Member.suggestedDirectory(agentId: "a-mateo", machineId: "m1", sessions: sessions, home: "/Users/m") == "/p/radar")
        #expect(AgentRoom.Member.suggestedDirectory(agentId: "a-tomas", machineId: "m1", sessions: sessions, home: "/Users/m") == "/p/escritorio")
        // An agent with no session on that machine starts at its home.
        #expect(AgentRoom.Member.suggestedDirectory(agentId: "a-leo", machineId: "m1", sessions: sessions, home: "/Users/m") == "/Users/m")
        #expect(AgentRoom.Member.suggestedDirectory(agentId: "a-leo", machineId: "m1", sessions: sessions, home: nil) == nil)
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
        #expect(Self.room(["lastSeq": 2]).waitingForUser(seats: seats, messages: unanswered)
            == [AgentRoom.Wait(agentId: "a-tomas", mentionSeq: 2, mentionedBy: "a-mateo")])
        // The user's own mention wakes anyone, and a paused room waits for the user to resume, not answer.
        #expect(Self.room(["lastSeq": 2, "pausedAt": 9]).waitingForUser(seats: seats, messages: unanswered).isEmpty)
    }

    @Test func aDismissedWaitStaysAwayUntilAnotherAgentMentionsTheMemberAgain() throws {
        // Mateo mentions Tomás in #2; the user dismisses Tomás's "Let It Answer" instead of letting it answer.
        let seats = [AgentRoomSeat(roomId: "r1", agentId: "a-tomas", readThroughSeq: 1)]
        let mentioned = [Self.message(1, by: Self.user, mentions: ["a-mateo"]), Self.message(2, by: Self.agent("a-mateo"), mentions: ["a-tomas"])]
        var room = Self.room(["lastSeq": 2])
        room.dismissWait(agentId: "a-tomas", mentionSeq: 2)
        #expect(room.waitingForUser(seats: seats, messages: mentioned).isEmpty)
        // Every device reads it from the room, and dismissing an older mention never brings a newer one back.
        let stored = try #require(AgentRoom(json: room.json))
        #expect(stored.members.first { $0.agentId == "a-tomas" }?.dismissedMentionSeq == 2)
        room.dismissWait(agentId: "a-tomas", mentionSeq: 1)
        #expect(room.members.first { $0.agentId == "a-tomas" }?.dismissedMentionSeq == 2)
        #expect(room.members.first { $0.agentId == "a-mateo" }?.dismissedMentionSeq == nil)

        // A later mention by an agent asks again.
        let again = mentioned + [Self.message(3, by: Self.agent("a-mateo"), mentions: ["a-tomas"])]
        #expect(room.waitingForUser(seats: seats, messages: again) == [AgentRoom.Wait(agentId: "a-tomas", mentionSeq: 3, mentionedBy: "a-mateo")])
    }

    @Test func aReplyReachesOnlyTheQuotedAgentPlusWhoeverTheUserMentions() throws {
        let room = Self.room(["lastSeq": 4])
        let tomas: JSONValue = ["kind": "agent", "agentId": "a-tomas", "name": "Tomás"]
        // Tomás's message mentions Mateo: quoting it doesn't carry that mention.
        let quoted = Self.message(4, by: tomas, mentions: ["a-mateo"], text: "Listo. @Mateo revisa")

        let (next, reply) = try #require(room.replying(to: quoted, with: " sí, adelante ", now: 9))
        #expect(next.lastSeq == 5)
        #expect(reply.text == "sí, adelante")
        #expect(reply.replyTo == 4)
        #expect(reply.mentions == ["a-tomas"])
        #expect(room.replyRecipients(to: quoted, text: "sí, adelante") == ["a-tomas"])

        // The members the user names are added, the quoted author first.
        #expect(room.replyRecipients(to: quoted, text: "y que @Mateo lo vea") == ["a-tomas", "a-mateo"])
        #expect(room.replyRecipients(to: quoted, text: "@todos atentos") == ["a-tomas", "a-mateo"])
        #expect(try #require(room.replying(to: quoted, with: "y que @Mateo lo vea", now: 9)).message.mentions == ["a-tomas", "a-mateo"])

        // Quoting the user's own message reaches no one by itself; nor does an agent no longer in the room.
        let mine = Self.message(3, by: Self.user, mentions: ["a-tomas"], text: "@Tomás ¿y esto?")
        #expect(room.replyRecipients(to: mine, text: "lo repito") == [])
        #expect(try #require(room.replying(to: mine, with: "lo repito", now: 9)).message.replyTo == 3)
        #expect(room.replyRecipients(to: Self.message(2, by: Self.agent("a-leo")), text: "ok") == [])
        #expect(room.replying(to: quoted, with: "  ", now: 9) == nil)
    }

    @Test func theBrakeHoldsAfterSixAgentTurnsInARowWithoutTheUser() {
        let agents = (2...7).map { Self.message($0, by: Self.agent($0.isMultiple(of: 2) ? "a-mateo" : "a-tomas")) }
        #expect(AgentRoom.brakeHolds([Self.message(1, by: Self.user)] + agents))
        #expect(!AgentRoom.brakeHolds([Self.message(1, by: Self.user)] + agents.dropLast()))
        #expect(!AgentRoom.brakeHolds(agents + [Self.message(8, by: Self.user)]))
    }

    @Test func anAgentsChatIsARoomOfJustItWhereEveryMessageReachesItWithoutAMention() throws {
        let mateo = AgentProfile(id: "a-mateo", name: "Mateo", providerId: "codex", account: .init(label: "ChatGPT"))
        let chat = AgentRoom.direct(with: mateo, machineId: "m1", directory: "/p", userName: "Manny", now: 7)
        // One chat per agent: every device makes the same one.
        #expect(chat.id == AgentRoom.directId(agentId: "a-mateo"))
        #expect(chat.isDirect && chat.directAgentId == "a-mateo")
        #expect(chat.title == "Mateo" && chat.userName == "Manny" && chat.members.map(\.agentId) == ["a-mateo"])
        #expect(chat.members.first?.machineId == "m1" && chat.members.first?.directory == "/p")
        let opened = try #require(AgentRoom.open(try chat.sealed(machineKey: Self.machineKey), machineKey: Self.machineKey))
        #expect(opened.isDirect && opened.directAgentId == "a-mateo")
        // No @ needed: it is the only one there.
        let (_, message) = try #require(chat.appendingUserMessage("¿Qué estás haciendo?", now: 8))
        #expect(message.mentions == ["a-mateo"])
        // A group room still reaches only who is mentioned.
        #expect(!Self.room().isDirect && Self.room().directAgentId == nil)
        #expect(Self.room().appendingUserMessage("hola", now: 8)?.message.mentions == [])
    }

    @Test func aMessageWrittenWhileTheAgentWorksWaitsForItsTurnToEnd() throws {
        let mateo = AgentProfile(id: "a-mateo", name: "Mateo", providerId: "codex", account: .init(label: "ChatGPT"))
        let chat = AgentRoom.direct(with: mateo, machineId: "m1", directory: "/p", userName: "Manny", now: 1)
        let messages = [Self.message(1, by: Self.user), Self.message(2, by: Self.user), Self.message(3, by: Self.agent("a-mateo")),
                        Self.message(4, by: Self.user)]
        func seat(read: Int, through: Int? = nil) -> AgentRoomSeat {
            AgentRoomSeat(roomId: chat.id, agentId: "a-mateo", readThroughSeq: read, inFlight: through.map { .init(throughSeq: $0, at: 5) })
        }
        // Mateo is working on #1: the user's #2 and #4 reach it when that turn ends; its own #3 never waits.
        let working = try #require(chat.queued(seats: [seat(read: 0, through: 1)], messages: messages))
        #expect(working.messages.map(\.seq) == [2, 4])
        #expect(working.reason == .afterCurrentTurn)
        #expect(working.revisable)
        // The turn ended and its daemon hasn't delivered them yet.
        let idle = try #require(chat.queued(seats: [seat(read: 1)], messages: messages))
        #expect(idle.messages.map(\.seq) == [2, 4] && idle.reason == .notDeliveredYet)
        // Delivered, or in the turn it's working: nothing waits.
        #expect(chat.queued(seats: [seat(read: 4)], messages: messages) == nil)
        #expect(chat.queued(seats: [seat(read: 1, through: 4)], messages: messages) == nil)
        // Before its first delivery it has no seat to guard a change with: they wait, and can't be changed.
        let first = try #require(chat.queued(seats: [], messages: messages))
        #expect(first.messages.map(\.seq) == [1, 2, 4] && !first.revisable)
        #expect(chat.settledThroughSeq(seats: [seat(read: 1, through: 2)]) == 2)
        // A group room has no queue: nothing there is edited or canceled.
        #expect(Self.room().queued(seats: [], messages: messages) == nil)
        #expect(Self.room().settledThroughSeq(seats: []) == .max)
    }

    @Test func anAgentsReplyFromAnotherThreadThanItsLastOneStartsANewThread() {
        func reply(_ seq: Int, _ agent: String, thread: String?) -> AgentRoomMessage {
            var author: [String: JSONValue] = ["kind": "agent", "agentId": .string(agent)]
            if let thread { author["sessionId"] = .string(thread) }
            return Self.message(seq, by: .object(author))
        }
        let messages = [Self.message(1, by: Self.user),
                        reply(2, "a-mateo", thread: "s1"),  // its first reply ever: nothing to compare with
                        Self.message(3, by: Self.user),
                        reply(4, "a-mateo", thread: "s1"),
                        reply(5, "a-tomas", thread: "t1"),  // another agent's thread is not Mateo's
                        reply(6, "a-mateo", thread: nil),   // no thread: never counts, and s1 stays its last
                        Self.message(7, by: Self.user),
                        reply(8, "a-mateo", thread: "s2"),  // its daemon opened a new thread
                        reply(9, "a-tomas", thread: "t1"),
                        reply(10, "a-mateo", thread: "s2"),
                        reply(11, "a-leo", thread: nil),
                        reply(12, "a-leo", thread: "l1")]   // its first reply from a known thread
        #expect(AgentRoom.newThreadSeqs(in: messages) == [8])
        // Read in seq order, however they arrive.
        #expect(AgentRoom.newThreadSeqs(in: messages.reversed()) == [8])
        #expect(AgentRoom.newThreadSeqs(in: []) == [])
    }

    @Test func anAgentsChatWorksFromTheHomeOfTheMachineItLastWorkedOn() throws {
        func session(_ id: String, agent: String?, machine: String, path: String, at: Double) throws -> Session {
            var metadata: [String: JSONValue] = ["path": .string(path), "machineId": .string(machine)]
            if let agent { metadata["agentIdentityV1"] = ["v": 1, "id": .string(agent), "name": "x"] }
            return try Session(row: ["id": .string(id), "seq": 1, "createdAt": 1, "updatedAt": .number(at), "active": false, "encryptionMode": "plain",
                                     "metadata": .string(String(decoding: try JSONValue.object(metadata).encoded(), as: UTF8.self)), "metadataVersion": 1],
                               keys: nil)
        }
        func machine(_ id: String, active: Bool, home: String, revoked: Bool = false) throws -> Machine {
            let marker = Data(#"{"t":"plain","v":null}"#.utf8).base64EncodedString()
            let doc = Data(#"{"t":"plain","v":{"host":"h","homeDir":"\#(home)"}}"#.utf8).base64EncodedString()
            var row: [String: JSONValue] = ["id": .string(id), "active": .bool(active), "dataEncryptionKey": .string(marker), "metadata": .string(doc)]
            if revoked { row["revokedAt"] = 5 }
            return try Machine(row: .object(row), keys: nil)
        }
        let sessions = [try session("a", agent: "a-mateo", machine: "m1", path: "/p/movil", at: 10),
                        try session("b", agent: "a-mateo", machine: "m2", path: "/p/radar", at: 30),
                        try session("c", agent: "a-tomas", machine: "m1", path: "/p/escritorio", at: 50)]
        let machines = [try machine("m0", active: true, home: "/old", revoked: true),
                        try machine("m1", active: false, home: "/Users/a"),
                        try machine("m2", active: true, home: "/Users/b")]
        // Its chat is with it, not about a project: the home of the machine it last worked on.
        let mateo = try #require(AgentRoom.directPlacement(agentId: "a-mateo", sessions: sessions, machines: machines))
        #expect(mateo.machineId == "m2" && mateo.directory == "/Users/b")
        let tomas = try #require(AgentRoom.directPlacement(agentId: "a-tomas", sessions: sessions, machines: machines))
        #expect(tomas.machineId == "m1" && tomas.directory == "/Users/a")
        // An agent with no session yet starts at the home of a machine that's on (never a revoked one).
        let leo = try #require(AgentRoom.directPlacement(agentId: "a-leo", sessions: sessions, machines: machines))
        #expect(leo.machineId == "m2" && leo.directory == "/Users/b")
        #expect(AgentRoom.directPlacement(agentId: "a-leo", sessions: [], machines: [machines[0]]) == nil)
    }

    @Test func theSidebarSelectsARoomLikeASessionButNeverReadsItAsOne() {
        let selection = AgentRoom.selection(id: "r1")
        #expect(AgentRoom.id(inSelection: selection) == "r1")
        #expect(AgentRoom.id(inSelection: AgentProfile.selection(id: "r1")) == nil)
        #expect(AgentProfile.id(inSelection: selection) == nil)
        #expect(AgentRoom.id(inSelection: "cmuenhmmr0isvpe01pzj907ri") == nil)
    }
}

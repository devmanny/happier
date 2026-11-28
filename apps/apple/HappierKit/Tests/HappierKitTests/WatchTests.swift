import Foundation
import Testing
@testable import HappierKit

/// What the iPhone and the Apple Watch exchange: the summary the phone leaves the watch and the
/// actions the watch sends back, plus the defaults a session started from the watch uses.
@MainActor
struct WatchTests {
    private let server = URL(string: "https://happier.nomada.cloud")!

    private func session(_ id: String, title: String, updated: Double, machine: String? = nil, path: String? = nil,
                         agent: String = "claude", active: Bool = true, unread: Bool = false,
                         request: (id: String, tool: String, arguments: JSONValue, kind: String?)? = nil) throws -> Session {
        var metadata: [String: JSONValue] = ["flavor": .string(agent), "summary": ["text": .string(title), "updatedAt": 1]]
        if let machine { metadata["machineId"] = .string(machine) }
        if let path { metadata["path"] = .string(path) }
        let document = String(decoding: try JSONValue.object(metadata).encoded(), as: UTF8.self)
        var session = try Session(row: ["id": .string(id), "seq": 0, "createdAt": 1, "updatedAt": .number(updated), "active": .bool(active),
                                        "activeAt": .number(updated), "encryptionMode": "plain", "metadata": .string(document),
                                        "metadataVersion": 1, "agentStateVersion": 1], keys: nil)
        if unread { session.unreadSince = Date(timeIntervalSince1970: updated / 1000) }
        if let request {
            var entry: [String: JSONValue] = ["tool": .string(request.tool), "arguments": request.arguments, "createdAt": .number(updated)]
            if let kind = request.kind { entry["kind"] = .string(kind) }
            session.agentState = ["requests": [request.id: .object(entry)]]
        }
        return session
    }

    private func machine(_ id: String, host: String, home: String, activeAt: Double?) throws -> Machine {
        let marker = Data(#"{"t":"plain","v":null}"#.utf8).base64EncodedString()
        let doc = Data(#"{"t":"plain","v":{"host":"\#(host)","homeDir":"\#(home)"}}"#.utf8).base64EncodedString()
        var row: [String: JSONValue] = ["id": .string(id), "active": .bool(activeAt != nil), "dataEncryptionKey": .string(marker), "metadata": .string(doc)]
        if let activeAt { row["activeAt"] = .number(activeAt) }
        return try Machine(row: .object(row), keys: nil)
    }

    // MARK: Watch → iPhone

    @Test func actionsRoundTripThroughTheConnectivityDictionary() {
        let messages: [WatchMessage] = [
            .permission(sessionId: "s1", requestId: "r1", tool: "Bash", allow: true),
            .permission(sessionId: "s1", requestId: "r2", tool: "Edit", allow: false),
            .reply(sessionId: "s2", text: "Go ahead"),
            .newSession(text: "Fix the flaky test"),
        ]
        for message in messages {
            #expect(WatchMessage(dictionary: message.dictionary) == message)
        }
        #expect(WatchMessage(dictionary: ["action": "dance"]) == nil)
        #expect(WatchMessage(dictionary: ["action": "reply", "sessionId": "s", "text": "   "]) == nil)
    }

    @Test func permissionsAndRepliesBecomeTheNotificationTapTheStoreAlreadyHandles() {
        let allow = WatchMessage.permission(sessionId: "s1", requestId: "r1", tool: "Bash", allow: true).pushTap
        #expect(allow == PushTap(sessionId: "s1", permission: .init(allow: true, requestId: "r1", tool: "Bash")))
        let reply = WatchMessage.reply(sessionId: "s2", text: "Go ahead").pushTap
        #expect(reply == PushTap(sessionId: "s2", permission: nil, reply: "Go ahead"))
        #expect(WatchMessage.newSession(text: "x").pushTap == nil)
    }

    @Test func outcomesRoundTrip() {
        let outcomes: [WatchReply] = [.done(sessionId: "s9"), .done(sessionId: nil), .failed("No machine is online.")]
        for outcome in outcomes {
            #expect(WatchReply(dictionary: outcome.dictionary) == outcome)
        }
        #expect(WatchReply(dictionary: [:]) == nil)
    }

    // MARK: iPhone → Watch

    @Test func contextCarriesBothSnapshotsAndSurvivesTheRoundTrip() throws {
        let sessions = [
            try session("a", title: "Deploy", updated: 2_000, request: ("r1", "Bash", ["command": "git push"], nil)),
            try session("b", title: "Fix", updated: 1_000, unread: true),
        ]
        let context = WatchContext(attention: AttentionSnapshot(sessions: sessions, server: server, limit: 6),
                                   activity: ActivitySnapshot(sessions: sessions, usage: [], server: server))
        let decoded = try #require(WatchContext(dictionary: context.dictionary))
        #expect(decoded == context)
        #expect(decoded.attention.items.map(\.sessionId) == ["a", "b"])
        #expect(WatchContext(dictionary: ["v": 1]) == nil)
    }

    @Test func contextSavesWhereTheWatchComplicationsRead() throws {
        let defaults = try #require(UserDefaults(suiteName: "watch-\(UUID().uuidString)"))
        let context = WatchContext(attention: AttentionSnapshot(total: 0, items: [], updatedAt: .now),
                                   activity: ActivitySnapshot(working: [], recent: [], usage: [], updatedAt: .now))
        context.save(to: defaults)
        #expect(AttentionSnapshot.load(from: defaults) == context.attention)
        #expect(ActivitySnapshot.load(from: defaults) == context.activity)
    }

    // MARK: What the watch shows for a waiting session

    @Test func attentionItemsCarryThePendingRequestAndTheAgentsLastWords() throws {
        let sessions = [
            try session("a", title: "Deploy", updated: 2_000, request: ("r1", "Bash", ["command": "git push origin main"], nil)),
            try session("b", title: "Fix", updated: 1_000, unread: true),
        ]
        let snapshot = AttentionSnapshot(sessions: sessions, server: server, limit: 6, excerpts: ["b": "All tests pass now."])
        let deploy = try #require(snapshot.items.first { $0.sessionId == "a" })
        #expect(deploy.request == AttentionSnapshot.Request(id: "r1", tool: "Bash", summary: "Bash: git push origin main"))
        #expect(deploy.lastAgentText == nil)
        let fix = try #require(snapshot.items.first { $0.sessionId == "b" })
        #expect(fix.request == nil)
        #expect(fix.lastAgentText == "All tests pass now.")
    }

    @Test func excerptsAreKeptShortAndSingleSpaced() throws {
        let long = String(repeating: "word ", count: 200)
        let snapshot = AttentionSnapshot(sessions: [try session("b", title: "Fix", updated: 1_000, unread: true)],
                                         server: server, limit: 6, excerpts: ["b": "  line one\n\n  line two  " + long])
        let text = try #require(snapshot.items.first?.lastAgentText)
        #expect(text.hasPrefix("line one line two word"))
        #expect(text.count <= 400)
    }

    @Test func snapshotsWrittenBeforeTheWatchStillDecode() throws {
        let legacy = Data("""
        {"total":1,"updatedAt":0,"items":[{"sessionId":"a","title":"Deploy","agentId":"claude","reason":"waitingForYou","date":0,"link":null}]}
        """.utf8)
        let snapshot = try JSONDecoder().decode(AttentionSnapshot.self, from: legacy)
        #expect(snapshot.items.first?.request == nil)
        #expect(snapshot.items.first?.lastAgentText == nil)
    }

    @Test func requestSummariesNameTheToolAndWhatItWants() {
        func summary(_ tool: String, _ arguments: JSONValue, kind: String? = nil) -> String {
            let entry: JSONValue = ["tool": .string(tool), "arguments": arguments, "kind": kind.map(JSONValue.string) ?? .null]
            let request = Transcript.pendingRequests(from: ["requests": ["r": entry]])
            return request[0].summary
        }
        #expect(summary("Bash", ["command": "ls -la"]) == "Bash: ls -la")
        #expect(summary("Edit", ["file_path": "/Users/m/app/Sources/Main.swift", "old_string": "a", "new_string": "b"]) == "Edit: Main.swift")
        #expect(summary("Write", ["file_path": "/tmp/notes.md", "content": "x"]) == "Write: notes.md")
        #expect(summary("WebFetch", ["url": "https://example.com/docs"]) == "WebFetch: https://example.com/docs")
        #expect(summary("AskUserQuestion", ["questions": [["question": "Which database should we use?"]]]) == "Which database should we use?")
        #expect(summary("ExitPlanMode", [:]) == "Approve the plan")
        #expect(summary("mcp__linear__create_issue", ["title": "Bug"]) == "Linear: Create Issue")
        #expect(summary("Bash", ["command": .string(String(repeating: "x", count: 300))]).count <= 160)
    }

    @Test func transcriptKnowsTheAgentsLastWords() {
        func raw(_ id: String, _ seq: Int, _ blocks: JSONValue) -> TranscriptMessage {
            TranscriptMessage(id: id, seq: seq, localId: nil, createdAt: Date(timeIntervalSince1970: Double(seq)),
                              record: ["role": "agent", "content": ["type": "output", "data": ["type": "assistant", "message": ["role": "assistant", "content": blocks]]]])
        }
        var transcript = Transcript()
        #expect(transcript.lastAgentText == nil)
        transcript.apply([
            raw("m1", 1, [["type": "text", "text": "Starting."]]),
            raw("m2", 2, [["type": "text", "text": "Done, tests pass."], ["type": "thinking", "thinking": "hmm"]]),
        ])
        #expect(transcript.lastAgentText == "Done, tests pass.")
    }

    // MARK: A session started from the watch

    @Test func newSessionUsesTheLastAgentAndTheLatestOnlineMachineAndFolder() throws {
        let defaults = try #require(UserDefaults(suiteName: "new-session-\(UUID().uuidString)"))
        defaults.set("codex", forKey: NewSessionDefaults.agentKey)
        defaults.set("gpt-5", forKey: NewSessionDefaults.modelKey("codex"))
        defaults.set("high", forKey: NewSessionDefaults.effortKey("codex"))
        let now = Date(timeIntervalSince1970: 1_000_000)
        let ms = now.timeIntervalSince1970 * 1000
        let machines = [
            try machine("old", host: "laptop", home: "/Users/a", activeAt: ms - 3_600_000),
            try machine("mini", host: "mini", home: "/Users/m", activeAt: ms - 1_000),
            try machine("vps", host: "vps", home: "/root", activeAt: ms - 2_000),
        ]
        let sessions = [
            try session("s1", title: "Newest but offline machine", updated: ms - 10, machine: "old", path: "/Users/a/x"),
            try session("s2", title: "Latest on an online machine", updated: ms - 20_000, machine: "vps", path: "/root/app"),
            try session("s3", title: "Older", updated: ms - 90_000, machine: "mini", path: "/Users/m/happier"),
        ]
        let chosen = try #require(NewSessionDefaults.resolve(machines: machines, sessions: sessions, defaults: defaults, now: now))
        #expect(chosen.machineId == "vps")
        #expect(chosen.directory == "/root/app")
        #expect(chosen.agentId == "codex")
        #expect(chosen.modelId == "gpt-5")
        #expect(chosen.effort == "high")
    }

    @Test func newSessionFallsBackToTheHomeFolderAndTheMostUsedAgent() throws {
        let defaults = try #require(UserDefaults(suiteName: "new-session-\(UUID().uuidString)"))
        let now = Date(timeIntervalSince1970: 1_000_000)
        let ms = now.timeIntervalSince1970 * 1000
        let machines = [try machine("mini", host: "mini", home: "/Users/m", activeAt: ms - 1_000)]
        let sessions = [
            try session("s1", title: "A", updated: ms - 10, machine: "elsewhere", path: "/x", agent: "codex"),
            try session("s2", title: "B", updated: ms - 20, machine: "elsewhere", path: "/y", agent: "codex"),
            try session("s3", title: "C", updated: ms - 30, machine: "elsewhere", path: "/z", agent: "claude"),
        ]
        let chosen = try #require(NewSessionDefaults.resolve(machines: machines, sessions: sessions, defaults: defaults, now: now))
        #expect(chosen.machineId == "mini")
        #expect(chosen.directory == "/Users/m")
        #expect(chosen.agentId == "codex")
        #expect(chosen.modelId == nil)
        #expect(chosen.effort == nil)
    }

    @Test func newSessionNeedsAnOnlineMachine() throws {
        let defaults = try #require(UserDefaults(suiteName: "new-session-\(UUID().uuidString)"))
        let now = Date(timeIntervalSince1970: 1_000_000)
        let machines = [try machine("old", host: "laptop", home: "/Users/a", activeAt: now.timeIntervalSince1970 * 1000 - 3_600_000)]
        #expect(NewSessionDefaults.resolve(machines: machines, sessions: [], defaults: defaults, now: now) == nil)
    }
}

import Foundation
import Testing
@testable import HappierKit

@Suite struct SessionModelTests {
    let keys = try! AccountKeys(masterSecret: Data(0..<32))
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var nowMs: Double { now.timeIntervalSince1970 * 1000 }

    private func e2eeRow(metadata: JSONValue, agentState: JSONValue? = nil, extra: [String: JSONValue] = [:]) throws -> JSONValue {
        let dataKey = Data(repeating: 9, count: 32)
        let envelope = try HappierCrypto.sealDataKeyEnvelope(dataKey, recipientPublicKey: keys.content.publicKey)
        let cipher = ContentCipher.aesGCM(key: dataKey)
        var row: [String: JSONValue] = [
            "id": "s1", "seq": 10, "createdAt": 1, "updatedAt": 2, "active": true, "activeAt": .number(nowMs),
            "encryptionMode": "e2ee", "dataEncryptionKey": .string(envelope.base64EncodedString()),
            "metadata": .string(try cipher.encryptBase64(metadata)), "metadataVersion": 3,
            "agentState": try agentState.map { .string(try cipher.encryptBase64($0)) } ?? .null, "agentStateVersion": 1,
        ]
        row.merge(extra) { $1 }
        return .object(row)
    }

    @Test func parentComesFromSpawnedBySessionNotFromForks() throws {
        let child = try Session(row: e2eeRow(metadata: [
            "path": "/a", "spawnedBySessionV1": ["v": 1, "parentSessionId": "p1", "createdAtMs": 1],
        ]), keys: keys)
        #expect(child.parentSessionId == "p1")
        let fork = try Session(row: e2eeRow(metadata: [
            "path": "/a", "forkV1": ["v": 1, "parentSessionId": "p1", "parentCutoffSeqInclusive": 3, "createdAtMs": 1, "strategy": "auto"],
        ]), keys: keys)
        #expect(fork.parentSessionId == nil)
    }

    @Test func decryptsE2EESessionAndDerivesDisplayFields() throws {
        let session = try Session(row: e2eeRow(metadata: [
            "path": "/Users/manny/Projects/app", "homeDir": "/Users/manny", "flavor": "codex-acp", "machineId": "m1",
            "summary": ["text": "Fix login", "updatedAt": 1],
        ]), keys: keys)
        #expect(session.title == "Fix login")
        #expect(session.displayPath == "~/Projects/app")
        #expect(session.agentId == "codex")
        #expect(session.metadataVersion == 3)
        #expect(session.cipher != nil)
    }

    @Test func titleFallsBackToNameThenFolder() throws {
        #expect(try Session(row: e2eeRow(metadata: ["path": "/x/my-repo", "name": "Named"]), keys: keys).title == "Named")
        #expect(try Session(row: e2eeRow(metadata: ["path": "/x/my-repo"]), keys: keys).title == "my-repo")
    }

    @Test func parsesPlainSessionsWithoutKeys() throws {
        let row: JSONValue = [
            "id": "p1", "seq": 1, "createdAt": 1, "updatedAt": 1, "active": false, "activeAt": 1,
            "encryptionMode": "plain", "metadata": #"{"path":"/srv/api","flavor":"claude"}"#, "metadataVersion": 1,
            "agentState": #"{"requests":{}}"#, "agentStateVersion": 1,
        ]
        let session = try Session(row: row, keys: nil)
        #expect(session.title == "api")
        #expect(session.agentId == "claude")
        #expect(session.cipher == nil && session.isPlain)
    }

    @Test func vendorSessionIdFollowsTheAgentsResumeField() throws {
        let row: JSONValue = ["id": "h1", "encryptionMode": "plain", "metadataVersion": 1,
                              "metadata": #"{"path":"/a","flavor":"codex","codexSessionId":"thread-9","claudeSessionId":"other"}"#]
        #expect(try Session(row: row, keys: nil).vendorSessionId == "thread-9")
        let none: JSONValue = ["id": "h2", "encryptionMode": "plain", "metadataVersion": 1, "metadata": #"{"path":"/a","flavor":"claude"}"#]
        #expect(try Session(row: none, keys: nil).vendorSessionId == nil)
    }

    @Test func hiddenSystemSessionsAreNotUserFacing() throws {
        let session = try Session(row: e2eeRow(metadata: ["path": "/a", "systemSessionV1": ["v": 1, "key": "k", "hidden": true]]), keys: keys)
        #expect(!session.isUserFacing)
    }

    /// A running session sends a heartbeat every few seconds; applying each one redrew every
    /// session list and kept the CPU busy. As in the RN app's `ActivityUpdateAccumulator`, only a
    /// visible change counts, or a timestamp 60 s newer (half the 120 s freshness window).
    @Test func onlySignificantActivityChangesTheSession() throws {
        let session = try Session(row: e2eeRow(metadata: ["path": "/a"], extra: ["active": true, "activeAt": .number(nowMs)]), keys: keys)
        #expect(session.applying(activity: ["active": true, "activeAt": .number(nowMs + 5_000)]) == nil)
        #expect(session.applying(activity: ["active": true, "activeAt": .number(nowMs + 61_000)])?.activeAt
            == Date(timeIntervalSince1970: (nowMs + 61_000) / 1000))
        #expect(session.applying(activity: ["active": true, "thinking": true, "activeAt": .number(nowMs + 1_000)])?.status(at: now) == .working)
        #expect(session.applying(activity: ["active": false, "activeAt": .number(nowMs + 1_000)])?.active == false)
    }

    /// The turn's end and the last "thinking" heartbeat race. When the completed turn lands
    /// first, the heartbeat is ignored (the turn is over), and `thinking` stayed true: auto read
    /// then held the last message until something else arrived.
    @Test func aFinishedTurnIsNotThinking() throws {
        var session = try Session(row: e2eeRow(metadata: ["path": "/a"], extra: ["active": true, "activeAt": .number(nowMs)]), keys: keys)
        session.apply(activity: ["active": true, "thinking": true, "activeAt": .number(nowMs)])
        #expect(session.thinking)
        try session.apply(update: ["t": "update-session", "id": .string(session.id), "latestTurnStatus": "completed",
                                   "latestTurnStatusObservedAt": .number(nowMs + 1_000)])
        #expect(!session.thinking)
        // A late "thinking" heartbeat from the finished turn doesn't bring it back.
        session.apply(activity: ["active": true, "thinking": true, "activeAt": .number(nowMs + 2_000)])
        #expect(!session.thinking)
        // A row read with a finished turn isn't thinking either.
        let row = try Session(row: e2eeRow(metadata: ["path": "/a"], extra: ["thinking": true, "latestTurnStatus": "completed"]), keys: keys)
        #expect(!row.thinking)
    }

    /// The idle cleaner's stop (`sessionRestV1`, written by `happier session stop --reason idle`)
    /// reads as resting until the session starts again (`lifecycleStateSince`); a stop of the
    /// user's own never does.
    @Test func restingIsAnIdleStopNoOlderThanTheLastStart() throws {
        func session(_ metadata: JSONValue, active: Bool = false, archived: Bool = false) throws -> Session {
            try Session(row: e2eeRow(metadata: metadata, extra: ["active": .bool(active), "archivedAt": archived ? .number(nowMs) : .null]),
                        keys: keys)
        }
        let rest: JSONValue = ["v": 1, "reason": "idle", "at": 2_000]
        #expect(try session(["path": "/a", "lifecycleStateSince": 1_000, "sessionRestV1": rest]).isResting)
        // The same instant: the stop came after the start it ended.
        #expect(try session(["path": "/a", "lifecycleStateSince": 2_000, "sessionRestV1": rest]).isResting)
        // Started again since (and then stopped by the user): stopped, not resting.
        #expect(try !session(["path": "/a", "lifecycleStateSince": 3_000, "sessionRestV1": rest]).isResting)
        // Running, archived, or never put to rest.
        #expect(try !session(["path": "/a", "lifecycleStateSince": 1_000, "sessionRestV1": rest], active: true).isResting)
        #expect(try !session(["path": "/a", "lifecycleStateSince": 1_000, "sessionRestV1": rest], archived: true).isResting)
        #expect(try !session(["path": "/a", "lifecycleStateSince": 1_000]).isResting)
        // Only what the CLI writes counts.
        #expect(try !session(["path": "/a", "sessionRestV1": ["v": 1, "reason": "user", "at": 2_000]]).isResting)
        #expect(try !session(["path": "/a", "sessionRestV1": ["v": 2, "reason": "idle", "at": 2_000]]).isResting)
        // No recorded start: the rest is the latest thing known about it.
        #expect(try session(["path": "/a", "sessionRestV1": rest]).isResting)
        // Resting is a way of not running: everything that acts on a stopped session still sees one.
        #expect(try session(["path": "/a", "sessionRestV1": rest]).status(at: now) == .offline)
    }

    @Test func statusFollowsUIPrecedence() throws {
        var session = try Session(row: e2eeRow(metadata: ["path": "/a"], extra: ["pendingPermissionRequestCount": 1]), keys: keys)
        #expect(session.status(at: now) == .permissionRequired)

        session = try Session(row: e2eeRow(metadata: ["path": "/a"], extra: [
            "latestTurnStatus": "in_progress", "latestTurnStatusObservedAt": .number(nowMs - 5_000)]), keys: keys)
        #expect(session.status(at: now) == .working)

        session = try Session(row: e2eeRow(metadata: ["path": "/a"], extra: [
            "latestTurnStatus": "in_progress", "latestTurnStatusObservedAt": .number(nowMs - 600_000), "activeAt": .number(nowMs - 600_000)]), keys: keys)
        #expect(session.status(at: now) == .idle)

        session = try Session(row: e2eeRow(metadata: ["path": "/a"], extra: ["active": false]), keys: keys)
        #expect(session.status(at: now) == .offline)
    }

    @Test func undecryptableRowThrows() throws {
        let other = try AccountKeys(masterSecret: Data(repeating: 1, count: 32))
        #expect(throws: (any Error).self) { try Session(row: e2eeRow(metadata: ["path": "/a"]), keys: other) }
    }

    @Test func decodesMessageEnvelopes() throws {
        let session = try Session(row: e2eeRow(metadata: ["path": "/a"]), keys: keys)
        let record: JSONValue = ["role": "user", "content": ["type": "text", "text": "hola"]]
        let c = try session.cipher!.encryptBase64(record)
        let encrypted = try TranscriptMessage(row: ["id": "m", "seq": 4, "localId": "L", "createdAt": 1000, "content": ["t": "encrypted", "c": .string(c)]], session: session)
        #expect(encrypted.record == record && encrypted.seq == 4 && encrypted.localId == "L")
        let legacy = try TranscriptMessage(row: ["id": "m", "seq": 4, "createdAt": 1000, "content": .string(c)], session: session)
        #expect(legacy.record == record)
        let plain = try TranscriptMessage(row: ["id": "m", "seq": 5, "createdAt": 1000, "content": ["t": "plain", "v": record]], session: session)
        #expect(plain.record == record)
        #expect(throws: (any Error).self) { try TranscriptMessage(row: ["id": "m", "seq": 6, "createdAt": 1, "content": ["t": "weird"]], session: session) }
    }

    @Test func withoutHeartbeatsATurnStaysWorkingUntilTheRelaySaysOtherwise() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let stale = now.timeIntervalSince1970 * 1000 - 600_000
        var session = try Session(row: e2eeRow(metadata: ["path": "/a"], extra: ["activeAt": .number(stale)]), keys: keys)
        session.latestTurnStatus = "in_progress"
        // A relay that sends heartbeats: a turn silent for 10 minutes isn't shown working.
        #expect(session.status(at: now, heartbeats: true) == .idle)
        // A lean relay sends no heartbeats, only state changes: the turn is still running.
        #expect(session.status(at: now, heartbeats: false) == .working)
        session.latestTurnStatus = "completed"
        #expect(session.status(at: now, heartbeats: false) == .idle)
    }
}

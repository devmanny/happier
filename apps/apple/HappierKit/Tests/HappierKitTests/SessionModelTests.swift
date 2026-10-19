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

    @Test func decryptsE2EESessionAndDerivesDisplayFields() throws {
        let session = try Session(row: e2eeRow(metadata: [
            "path": "/Users/manny/Projects/app", "homeDir": "/Users/manny", "flavor": "codex-acp", "machineId": "m1",
            "summary": ["text": "Fix login", "updatedAt": 1],
        ]), keys: keys)
        #expect(session.title == "Fix login")
        #expect(session.displayPath == "~/Projects/app")
        #expect(session.agentId == "codex")
        #expect(session.avatarId == "s1:m1:/Users/manny/Projects/app")
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

    @Test func hiddenSystemSessionsAreNotUserFacing() throws {
        let session = try Session(row: e2eeRow(metadata: ["path": "/a", "systemSessionV1": ["v": 1, "key": "k", "hidden": true]]), keys: keys)
        #expect(!session.isUserFacing)
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
}

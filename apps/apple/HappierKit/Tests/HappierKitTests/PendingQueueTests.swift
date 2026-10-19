import Foundation
import Testing
@testable import HappierKit

/// Steering and the server pending queue (`submitMode.ts`, `pendingRoutes.ts`, `pendingQueueV2.ts`).
@Suite struct PendingQueueTests {
    private func session(active: Bool = true, seq: Int = 5, agentStateVersion: Int = 2, capabilities: JSONValue? = nil) throws -> Session {
        var row: [String: JSONValue] = [
            "id": "s", "seq": .number(Double(seq)), "createdAt": 1, "updatedAt": 1, "active": .bool(active), "activeAt": 1,
            "encryptionMode": "plain", "metadata": #"{"path":"/a"}"#, "metadataVersion": 1, "agentStateVersion": .number(Double(agentStateVersion)),
            "pendingVersion": 3,
        ]
        if let capabilities {
            row["agentState"] = .string(String(decoding: try (["capabilities": capabilities] as JSONValue).encoded(), as: UTF8.self))
        }
        return try Session(row: .object(row), keys: nil)
    }

    @Test func steersByDefaultWhenTheAgentSupportsIt() throws {
        let s = try session(capabilities: ["inFlightSteerSupported": true, "inFlightSteerAvailable": true])
        #expect(SendDecision.action(for: "fix the tests", session: s) == .steerIfActive)
        // Legacy single flag.
        #expect(SendDecision.action(for: "hi", session: try session(capabilities: ["inFlightSteer": true])) == .steerIfActive)
    }

    @Test func queuesWhenSteeringIsUnsupportedOrUnsafe() throws {
        #expect(SendDecision.action(for: "hi", session: try session(capabilities: ["inFlightSteerSupported": false])) == .enqueue)
        #expect(SendDecision.action(for: "hi", session: try session(active: false, capabilities: ["inFlightSteerSupported": true])) == .enqueue)
        #expect(SendDecision.action(for: "hi", session: try session(agentStateVersion: 0)) == .enqueue)
        let steerable = try session(capabilities: ["inFlightSteerSupported": true])
        #expect(SendDecision.action(for: "/compact", session: steerable) == .enqueue)
        #expect(SendDecision.action(for: " /clear ", session: steerable) == .enqueue)
    }

    @Test func firstTurnSendsNow() throws {
        #expect(SendDecision.action(for: "start", session: try session(seq: 0, capabilities: ["inFlightSteerSupported": true])) == .sendNow)
    }

    @Test func parsesQueuedAndDiscardedRowsInDisplayOrder() throws {
        let s = try session()
        let record: JSONValue = ["role": "user", "content": ["type": "text", "text": "raw"], "meta": ["displayText": "shown"]]
        let rows: [JSONValue] = [
            ["localId": "b", "content": ["t": "plain", "v": record], "status": "queued", "position": 2, "createdAt": 10, "updatedAt": 10,
             "deliveryStatus": ["status": "queued"], "discardedAt": nil],
            ["localId": "a", "content": ["t": "plain", "v": record], "status": "queued", "position": 1, "createdAt": 20, "updatedAt": 20,
             "deliveryStatus": ["status": "blocked", "reason": "steering_unavailable"], "deliveryBlockedReason": "steering_unavailable"],
            ["localId": "d", "content": ["t": "plain", "v": record], "status": "discarded", "position": 0, "createdAt": 5, "updatedAt": 30,
             "discardedAt": 30, "discardedReason": "switch_to_local", "deliveryStatus": ["status": "discarded", "reason": "switch_to_local"]],
            ["localId": "x", "content": ["t": "plain", "v": record], "status": "discarded", "position": 0, "createdAt": 5, "updatedAt": 40,
             "discardedAt": 40, "discardedReason": "resent_as_new"],
        ]
        let items = PendingMessage.list(rows, session: s)
        #expect(items.map(\.localId) == ["a", "b", "d"])
        #expect(items[0].text == "shown" && items[0].state == .blocked(reason: "steering_unavailable"))
        #expect(items[1].state == .queued)
        #expect(items[2].state == .discarded)
    }

    @Test func editReplacesTextAndDropsAppendedSystemPrompt() {
        let record: JSONValue = ["role": "user", "content": ["type": "text", "text": "old"], "meta": ["displayText": "old", "appendSystemPrompt": "x", "sentFrom": "ios"]]
        let edited = PendingMessage.editedRecord(record, text: "new")
        #expect(edited["content"]?["text"] == "new")
        #expect(edited["meta"]?["displayText"] == "new")
        #expect(edited["meta"]?["appendSystemPrompt"] == nil)
        #expect(edited["meta"]?["sentFrom"] == "ios")
    }
}

import Foundation
import Testing
@testable import HappierKit

/// Steering and the server pending queue (`submitMode.ts`, `pendingRoutes.ts`, `pendingQueueV2.ts`).
@Suite struct PendingQueueTests {
    private func session(active: Bool = true, seq: Int = 5, agentStateVersion: Int = 2, thinking: Bool = false,
                         capabilities: JSONValue? = nil) throws -> Session {
        var row: [String: JSONValue] = [
            "id": "s", "seq": .number(Double(seq)), "createdAt": 1, "updatedAt": 1, "active": .bool(active), "activeAt": 1,
            "encryptionMode": "plain", "metadata": #"{"path":"/a"}"#, "metadataVersion": 1, "agentStateVersion": .number(Double(agentStateVersion)),
            "pendingVersion": 3, "thinking": .bool(thinking),
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

    /// Steer Now, in the session chat and in an agent's chat: a turn is under way and the agent can
    /// take a steer into it right now.
    @Test func steerNowIsOfferedOnlyWhileATurnRunsThatCanTakeIt() throws {
        let now = Date(timeIntervalSince1970: 1)
        #expect(try session(thinking: true, capabilities: ["inFlightSteerAvailable": true]).canSteerNow(at: now))
        #expect(try session(thinking: true, capabilities: ["inFlightSteer": true]).canSteerNow(at: now))
        #expect(try !session(thinking: true, capabilities: ["inFlightSteerSupported": true, "inFlightSteerAvailable": false]).canSteerNow(at: now))
        #expect(try !session(thinking: false, capabilities: ["inFlightSteerAvailable": true]).canSteerNow(at: now))
    }

    @Test func firstTurnSendsNow() throws {
        #expect(SendDecision.action(for: "start", session: try session(seq: 0, capabilities: ["inFlightSteerSupported": true])) == .sendNow)
    }

    /// The relay's own id for the copy (`derivePendingSendAsNewLocalId`, `pendingMessageService.ts`).
    /// The second pair is from a real session: the relay hid `fdbcca5b…` and delivered its copy.
    @Test func theCopyOfAMessageSentAgainAsNewCarriesTheRelaysId() {
        #expect(PendingMessage.sentAsNewLocalId(sessionId: "s1", localId: "p1")
            == "send-as-new-6c577788585c1178c259df139f627803076130ae679d69ac8256a15b7cf1453f")
        #expect(PendingMessage.sentAsNewLocalId(sessionId: "cmwgor3vx70rpqh01uo7raxiy", localId: "fdbcca5b-17c3-4207-ba09-d6f0ae390e73")
            == "send-as-new-580dfb8cf93a91858ce32834bfd1f345ceb84c62f13df849026cdf1757923ffd")
    }

    @Test func parsesQueuedAndDiscardedRowsInDisplayOrder() throws {
        let s = try session()
        let record: JSONValue = ["role": "user", "content": ["type": "text", "text": "raw"], "meta": ["displayText": "shown"]]
        let rows: [JSONValue] = [
            ["localId": "b", "content": ["t": "plain", "v": record], "status": "queued", "position": 2, "createdAt": 10, "updatedAt": 10,
             "deliveryStatus": ["status": "queued"], "discardedAt": .null],
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

    /// A delivery the agent may already have (`isPendingDeliveryProviderEffectPossibleV1`): the
    /// relay refuses Retry/Send now/Edit/Remove on it, so it is its own state, read from the
    /// relay's normalized `deliveryStatus` rather than the raw column.
    @Test func aDeliveryTheAgentMayHaveIsUncertainNotBlocked() throws {
        let s = try session()
        let record: JSONValue = ["role": "user", "content": ["type": "text", "text": "hola"]]
        var position = 0.0
        func row(_ localId: String, _ status: JSONValue, raw: JSONValue = .null) -> JSONValue {
            position += 1
            return ["localId": .string(localId), "content": ["t": "plain", "v": record], "status": "queued", "position": .number(position), "createdAt": 1,
             "updatedAt": 1, "deliveryState": "blocked", "deliveryBlockedReason": raw, "deliveryStatus": status]
        }
        let items = PendingMessage.list([
            row("u", ["status": "blocked", "reason": "delivery_outcome_uncertain"], raw: "delivery_outcome_uncertain"),
            row("a", ["status": "blocked", "reason": "ambiguous_terminal_delivery"], raw: "ambiguous_terminal_delivery"),
            // A raw reason this relay doesn't know is normalized to `unknown`: it may have arrived.
            row("k", ["status": "blocked", "reason": "unknown"], raw: "some_future_reason"),
            row("s", ["status": "blocked", "reason": "steering_unavailable"], raw: "steering_unavailable"),
            // A malformed requested action: the relay reports it unsupported, with no raw reason.
            row("m", ["status": "blocked", "reason": "unsupported_action"]),
        ], session: s)
        #expect(items.map(\.state) == [
            .uncertain(reason: "delivery_outcome_uncertain"),
            .uncertain(reason: "ambiguous_terminal_delivery"),
            .uncertain(reason: "unknown"),
            .blocked(reason: "steering_unavailable"),
            .blocked(reason: "unsupported_action"),
        ])
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

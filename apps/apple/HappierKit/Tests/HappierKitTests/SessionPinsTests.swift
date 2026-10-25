import Testing
@testable import HappierKit

/// Pinned conversations come from the account's session organization (`/v2/session-organization`),
/// shared with the official app; order matches `projection.ts`.
@Suite struct SessionPinsTests {
    @Test func readsPinsFromTheOrganizationSnapshot() {
        let snapshot: JSONValue = ["snapshot": ["schemaVersion": 1, "version": 3, "pins": [
            ["sessionId": "b", "sortKey": .null, "pinnedAt": 200],
            ["sessionId": "a", "sortKey": .null, "pinnedAt": 100],
            ["sessionId": "c", "sortKey": "m", "pinnedAt": 300],
        ], "folders": [], "folderAssignments": [], "tags": [], "tagAssignments": [], "orderEntries": [], "labels": []]]
        // Explicit sort keys first, then the order they were pinned in.
        #expect(SessionPins.orderedIds(fromSnapshot: snapshot) == ["c", "a", "b"])
        #expect(SessionPins.orderedIds(fromSnapshot: ["error": "x"]) == [])
    }

    @Test func pinnedSessionsLeadAndKeepTheirPinOrder() {
        let ordered = SessionPins.pinnedFirst(["x", "c", "y", "a"], pinned: ["a", "c"]) { $0 }
        #expect(ordered == ["a", "c", "x", "y"])
    }
}

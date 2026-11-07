import Foundation
import Testing
@testable import HappierKit

/// The session's bell (`notificationsMutedV1`, `packages/protocol/src/sessionMetadata/sessionNotificationsMutedV1.ts`):
/// on by default; off means the session never notifies, the CLI reads it before every notification.
@Suite struct SessionNotificationsTests {
    private func session(_ metadata: JSONValue) throws -> Session {
        try Session(row: ["id": "s", "seq": 1, "createdAt": 1, "updatedAt": 1, "active": false, "encryptionMode": "plain",
                          "metadata": .string(String(decoding: try metadata.encoded(), as: UTF8.self)), "metadataVersion": 1], keys: nil)
    }

    @Test func theBellIsOnUntilTheUserTurnsItOff() throws {
        let fresh: JSONValue = ["path": "/repo"]
        #expect(try session(fresh).notificationsMuted == false)

        let muted = MetadataEdit.setNotificationsMuted(true, in: fresh, now: 10)
        #expect(muted["notificationsMutedV1"] == ["v": 1, "muted": true, "updatedAt": 10])
        #expect(muted["path"] == "/repo")
        #expect(try session(muted).notificationsMuted == true)

        #expect(try session(MetadataEdit.setNotificationsMuted(false, in: muted, now: 11)).notificationsMuted == false)
    }
}

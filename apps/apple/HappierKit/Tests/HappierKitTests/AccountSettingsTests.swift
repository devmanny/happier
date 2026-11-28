import Foundation
import Testing
@testable import HappierKit

/// Account-synced settings (`/v2/account/settings`, `accountScopedCipher.ts`, `accountSettings.ts`,
/// `notificationChannels.ts`).
@Suite struct AccountSettingsTests {
    let keys = try! AccountKeys(masterSecret: Data(0..<32))

    /// Sealed by `sealAccountScopedBlobCiphertext({kind:'account_settings', material:{type:'legacy', secret:0..31}})`
    /// with a nonce of 7s; the legacy one is a bare `nonce(3s) ‖ secretbox(json, rawSecret)`.
    static let tsSealed = "oQEHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcnFtwoka5jw/9P6ZnFD078wH5UEqTFE8qSiwLjIDpoCgqNjUPckr8JFxW4YSLE3dm78RmNkfusPTng/G9ZXkgh42X+v56v3LUcfYLREeuN2uPbFhFRt/uJnQ=="
    static let tsLegacy = "AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDJIN+n/uWVOH5btjWey2H6+83egq98cMtJZC3a8fDOMGXIbvWGmKmJOZGFcQB9nxPvx/tXtQNcb0QYCVPO3lgXg5P/m/Vp3SKNEeAJ9O2XfiHQP34HZ8A3qE="
    static let tsPayload: [String: JSONValue] = ["notificationsSettingsV1": ["v": 1, "pushEnabled": false], "someRnKey": ["x"]]

    @Test func opensWhatTheTypeScriptClientSeals() {
        #expect(AccountSettingsContent.open(["t": "encrypted", "c": .string(Self.tsSealed)], keys: keys) == Self.tsPayload)
        #expect(AccountSettingsContent.open(["t": "encrypted", "c": .string(Self.tsLegacy)], keys: keys) == Self.tsPayload)
    }

    @Test func sealsInTheCurrentFormatAndPlainAccountsStayPlain() throws {
        let values: [String: JSONValue] = ["a": 1, "b": ["c": true]]
        let sealed = try AccountSettingsContent.seal(values, keys: keys, plain: false)
        #expect(sealed["t"] == "encrypted")
        let bytes = try #require(sealed["c"]?.stringValue.flatMap(Base64.decode))
        #expect(bytes.prefix(2) == Data([0xA1, 0x01]))
        #expect(AccountSettingsContent.open(sealed, keys: keys) == values)
        let plain = try AccountSettingsContent.seal(values, keys: nil, plain: true)
        #expect(plain == ["t": "plain", "v": .object(values)])
        #expect(AccountSettingsContent.open(plain, keys: nil) == values)
    }

    @Test func emptyContentIsAnEmptyDocumentButAWrongKeyIsUnreadable() {
        #expect(AccountSettingsContent.open(nil, keys: keys) == [:])
        #expect(AccountSettingsContent.open(.null, keys: keys) == [:])
        let other = try! AccountKeys(masterSecret: Data(repeating: 1, count: 32))
        #expect(AccountSettingsContent.open(["t": "encrypted", "c": .string(Self.tsSealed)], keys: other) == nil)
    }

    @Test func notificationsDefaultToOnAndMuteToOff() {
        let empty = AccountSettings(values: [:])
        #expect(empty.notifications == .init())
        #expect(empty.notifications.pushEnabled && empty.notifications.permissionRequest && !empty.notifications.mutePhoneWhenComputerFocused)
        let stored = AccountSettings(values: ["notificationsSettingsV1": ["v": 1, "ready": false, "foregroundBehavior": "silent", "mutePhoneWhenComputerFocused": true]])
        #expect(!stored.notifications.ready && stored.notifications.foregroundBehavior == .silent && stored.notifications.mutePhoneWhenComputerFocused)
        #expect(stored.notifications.pushEnabled)
    }

    /// The CLI delivers by `notificationChannelsV1` whenever it exists, so both keys change together,
    /// webhook channels are kept and fields the native app doesn't show survive.
    @Test func changingNotificationsRewritesThePushChannelAndKeepsWebhooks() {
        let webhook: JSONValue = ["v": 1, "id": "hook1", "kind": "webhook", "enabled": true, "url": "https://example.com",
                                  "topics": ["ready": true, "permissionRequest": true, "userActionRequest": true]]
        let settings = AccountSettings(values: [
            "notificationsSettingsV1": ["v": 1, "connectedServiceQuotaBlocked": false],
            "notificationChannelsV1": [["v": 1, "id": "builtin:expo_push", "kind": "expo_push", "enabled": true], webhook],
            "untouched": "yes",
        ])
        var notifications = settings.notifications
        notifications.pushEnabled = false
        notifications.permissionRequest = false
        let next = settings.merging(settings.delta(notifications: notifications))
        #expect(next.values["untouched"] == "yes")
        #expect(next.values["notificationsSettingsV1"]?["pushEnabled"] == false)
        #expect(next.values["notificationsSettingsV1"]?["connectedServiceQuotaBlocked"] == false)
        #expect(next.values["notificationChannelsV1"] == [
            ["v": 1, "id": "builtin:expo_push", "kind": "expo_push", "enabled": false,
             "topics": ["ready": true, "permissionRequest": false, "userActionRequest": true, "connectedServiceAccountSwitch": true,
                        "connectedServiceQuotaBlocked": false, "connectedServiceQuotaRecovered": true],
             "readyIncludeMessageText": true, "requestIncludeMessageText": true],
            webhook,
        ])
    }

    @Test func defaultPermissionModesAreKeyedByBackendTarget() {
        let settings = AccountSettings(values: ["sessionDefaultPermissionModeByTargetKey": ["agent:claude": "acceptEdits", "agent:codex": "yolo"]])
        #expect(settings.defaultPermissionMode(for: "claude") == .safeYolo)
        #expect(settings.defaultPermissionMode(for: "codex") == .yolo)
        #expect(settings.defaultPermissionMode(for: "gemini") == nil)
        let next = settings.merging(settings.delta(defaultPermissionMode: .readOnly, for: "gemini"))
        #expect(next.values["sessionDefaultPermissionModeByTargetKey"] == ["agent:claude": "acceptEdits", "agent:codex": "yolo", "agent:gemini": "read-only"])
        let cleared = next.merging(next.delta(defaultPermissionMode: nil, for: "codex"))
        #expect(cleared.defaultPermissionMode(for: "codex") == nil && cleared.defaultPermissionMode(for: "claude") == .safeYolo)
    }
    @Test func theAgentOrderRoundTripsThroughTheSealedDocumentAndKeepsOtherClientsKeys() throws {
        let settings = AccountSettings(values: ["someRnKey": ["x"], "notificationsSettingsV1": ["v": 1, "pushEnabled": false]])
        #expect(settings.agentOrder == [])
        let next = settings.merging(settings.delta(agentOrder: ["tomas", "julian"]))
        let sealed = try AccountSettingsContent.seal(next.values, keys: keys, plain: false)
        let reopened = AccountSettings(values: try #require(AccountSettingsContent.open(sealed, keys: keys)))
        #expect(reopened.agentOrder == ["tomas", "julian"])
        #expect(reopened.values["someRnKey"] == ["x"])
        #expect(reopened.values["notificationsSettingsV1"] == ["v": 1, "pushEnabled": false])
        // Something unreadable under the key is no order, not a crash or a half order.
        #expect(AccountSettings(values: ["nativeAgentOrderV1": "tomas"]).agentOrder == [])
        #expect(AccountSettings(values: ["nativeAgentOrderV1": ["tomas", 3, "", "julian"]]).agentOrder == ["tomas", "julian"])
    }
}

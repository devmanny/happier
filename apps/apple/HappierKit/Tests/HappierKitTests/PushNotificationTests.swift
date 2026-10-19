import Foundation
import Testing
@testable import HappierKit

/// Mirrors `expo-notifications` `getExpoPushTokenAsync` and the UI's `notificationRouting.ts`.
@Suite struct PushNotificationTests {
    private func profile(_ entitlements: String) -> Data {
        // A provisioning profile is a CMS envelope around an XML plist.
        var data = Data([0x30, 0x82, 0x4e, 0x1f, 0x06, 0x09])
        data += Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>Entitlements</key><dict>\(entitlements)</dict></dict></plist>
            """.utf8)
        data += Data([0xa0, 0x82, 0x0d])
        return data
    }

    @Test func apnsEnvironmentComesFromTheEmbeddedProfile() {
        #expect(PushNotifications.usesDevelopmentAPNs(provisioningProfile: profile(
            "<key>aps-environment</key><string>development</string>")))
        #expect(PushNotifications.usesDevelopmentAPNs(provisioningProfile: profile(
            "<key>com.apple.developer.aps-environment</key><string>development</string>")))
        #expect(!PushNotifications.usesDevelopmentAPNs(provisioningProfile: profile(
            "<key>aps-environment</key><string>production</string>")))
        #expect(!PushNotifications.usesDevelopmentAPNs(provisioningProfile: nil))
    }

    @Test func expoTokenRequestMatchesExpoNotifications() throws {
        let installation = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        let body = PushNotifications.expoTokenRequest(
            deviceToken: Data([0x0a, 0xff, 0x01]), installationId: installation, development: true,
            bundleId: "com.devmanny.happier", projectId: "proj-1")
        #expect(body == [
            "type": "apns", "deviceId": "6f9619ff-8b86-d011-b42d-00c04fc964ff", "development": true,
            "appId": "com.devmanny.happier", "deviceToken": "0aff01", "projectId": "proj-1",
        ])
        #expect(PushNotifications.expoToken(from: ["data": ["expoPushToken": "ExponentPushToken[abc]"]]) == "ExponentPushToken[abc]")
        #expect(PushNotifications.expoToken(from: ["data": [:]]) == nil)
    }

    @Test func defaultTapOpensTheSessionFromExpoBody() {
        let userInfo: JSONValue = ["aps": ["alert": "hi"], "body": ["sessionId": "s1", "serverUrl": "https://h.example"]]
        let tap = PushNotifications.tap(userInfo: userInfo, action: PushNotifications.defaultAction)
        #expect(tap == PushTap(sessionId: "s1", permission: nil))
    }

    @Test func permissionActionsCarryTheRequest() {
        let userInfo: JSONValue = ["body": ["sessionId": "s1", "requestId": "r9", "kind": "permission", "tool": "Bash"]]
        #expect(PushNotifications.tap(userInfo: userInfo, action: PushNotifications.Action.allow)
            == PushTap(sessionId: "s1", permission: .init(allow: true, requestId: "r9", tool: "Bash")))
        #expect(PushNotifications.tap(userInfo: userInfo, action: PushNotifications.Action.deny)?.permission?.allow == false)
        // Without a request id the action degrades to opening the session.
        #expect(PushNotifications.tap(userInfo: ["body": ["sessionId": "s1"]], action: PushNotifications.Action.allow)
            == PushTap(sessionId: "s1", permission: nil))
        #expect(PushNotifications.tap(userInfo: userInfo, action: "SOMETHING_ELSE") == nil)
    }
}

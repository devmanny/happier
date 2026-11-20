import Foundation
import Testing
@testable import HappierKit

/// Mirrors the CLI's `apnsPush.ts` token format and the UI's `notificationRouting.ts`.
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

    @Test func registersTheAPNsTokenForTheCLIToDeliverDirectly() {
        // Parsed by `parseApnsPushToken` in `apps/cli/src/api/apnsPush.ts`.
        #expect(PushNotifications.apnsToken(deviceToken: Data([0x0a, 0xff, 0x01]), development: true, bundleId: "com.devmanny.happier")
            == "apns:sandbox:com.devmanny.happier:0aff01")
        #expect(PushNotifications.apnsToken(deviceToken: Data([0xab]), development: false, bundleId: "com.devmanny.happier")
            == "apns:production:com.devmanny.happier:ab")
    }

    @Test func defaultTapOpensTheSessionFromPushBody() {
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

    /// The Reply field on a session notification (category from `resolveCategoryIdFromPushData`).
    @Test func replyActionCarriesTheTypedText() {
        #expect(PushNotifications.Category.sessionMessage == "happier.sessionMessage.v1")
        let userInfo: JSONValue = ["body": ["sessionId": "s1"]]
        #expect(PushNotifications.tap(userInfo: userInfo, action: PushNotifications.Action.reply, replyText: "  sigue así \n")
            == PushTap(sessionId: "s1", permission: nil, reply: "sigue así"))
        // Nothing typed, or no session to send to: nothing to send.
        #expect(PushNotifications.tap(userInfo: userInfo, action: PushNotifications.Action.reply, replyText: "   ") == nil)
        #expect(PushNotifications.tap(userInfo: ["body": [:]], action: PushNotifications.Action.reply, replyText: "hola") == nil)
    }

    /// A room's notices (`completeRoomTurn`: every reply in an agent's chat, a mention, the brake)
    /// name the room, not a session: a tap opens the room.
    @Test func roomNoticeTapOpensTheRoom() {
        let reply: JSONValue = ["aps": ["alert": ["title": "Mateo", "body": "Listo"]],
                                "body": ["type": "room_mention", "roomId": "direct-a-mateo", "seq": 2]]
        #expect(PushNotifications.tap(userInfo: reply, action: PushNotifications.defaultAction)
            == PushTap(sessionId: nil, roomId: "direct-a-mateo", permission: nil))
        let brake: JSONValue = ["body": ["type": "room_brake", "roomId": "r1", "seq": 9]]
        #expect(PushNotifications.tap(userInfo: brake, action: PushNotifications.defaultAction)
            == PushTap(sessionId: nil, roomId: "r1", permission: nil))
        // A session's notice names no room.
        #expect(PushNotifications.tap(userInfo: ["body": ["sessionId": "s1"]], action: PushNotifications.defaultAction)?.roomId == nil)
    }

    /// No banner for the conversation on screen: its session, its room, or the agent's chat a room
    /// is, whether that chat was opened from the agent's circle or from a notification.
    @Test func noBannerForTheConversationOnScreen() {
        let session = PushTap(sessionId: "s1", permission: nil)
        #expect(session.isShown(in: "s1"))
        #expect(!session.isShown(in: "s2"))
        #expect(!session.isShown(in: nil))
        #expect(!session.isShown(in: AgentRoom.selection(id: "s1")))

        let room = PushTap(sessionId: nil, roomId: "r1", permission: nil)
        #expect(room.isShown(in: AgentRoom.selection(id: "r1")))
        #expect(!room.isShown(in: AgentRoom.selection(id: "r2")))
        #expect(!room.isShown(in: "r1"))
        #expect(!room.isShown(in: nil))

        let chat = PushTap(sessionId: nil, roomId: AgentRoom.directId(agentId: "a-mateo"), permission: nil)
        #expect(chat.isShown(in: AgentProfile.selection(id: "a-mateo")))
        #expect(chat.isShown(in: AgentRoom.selection(id: AgentRoom.directId(agentId: "a-mateo"))))
        #expect(!chat.isShown(in: AgentProfile.selection(id: "a-leo")))
        #expect(!room.isShown(in: AgentProfile.selection(id: "a-mateo")))
    }

    /// The in-app notification center keeps a session's newest notification only, like the
    /// device does with `apns-collapse-id`; the older ones are taken off the device too. A room's
    /// notices (every reply in an agent's chat) carry no session: the newest of each room stays.
    @Test func keepsTheNewestNotificationOfEachSession() {
        func note(_ id: String, _ session: String?, room: String? = nil, _ at: Double) -> DeliveredNotification {
            DeliveredNotification(id: id, sessionId: session, roomId: room, title: id, body: "", date: Date(timeIntervalSince1970: at))
        }
        let delivered = [note("a1", "A", 1), note("b1", "B", 2), note("a2", "A", 3), note("x", nil, 4), note("y", nil, 0),
                         note("m1", nil, room: "direct-a-mateo", 5), note("m2", nil, room: "direct-a-mateo", 6),
                         note("r1", nil, room: "r1", 1.5),
                         // A room id that is also a session id stays apart from that session.
                         note("bb", nil, room: "B", 2.5)]
        let feed = PushNotifications.latestPerSession(delivered)
        #expect(feed.latest.map(\.id) == ["m2", "x", "a2", "bb", "b1", "r1", "y"])
        #expect(feed.stale == ["m1", "a1"])
    }
}

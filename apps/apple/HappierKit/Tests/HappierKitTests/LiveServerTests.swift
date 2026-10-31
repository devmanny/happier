import Foundation
import Testing
@testable import HappierKit

/// Opt-in checks against a real Happier server: `HAPPIER_LIVE_SERVER=https://api.happier.dev swift test`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HAPPIER_LIVE_SERVER"] != nil))
struct LiveServerTests {
    let server = URL(string: ProcessInfo.processInfo.environment["HAPPIER_LIVE_SERVER"] ?? "https://api.happier.dev")!

    @Test func socketHandshakeRejectsInvalidToken() async throws {
        let client = SocketIOClient(
            serverURL: server, path: "/v1/updates",
            auth: ["token": "invalid-token", "clientType": "user-scoped"]
        )
        let error = await #expect(throws: SocketIOClient.ConnectError.self) { try await client.connect() }
        // A namespace-level rejection (Socket.IO "44"), not a transport failure.
        #expect(error?.message.hasPrefix("connect error") == false)
    }

    @Test func accountLinkRequestIsAcceptedAndPending() async throws {
        let auth = AuthAPI(server: server)
        let pair = try await auth.startAccountLink()
        let poll = Task { try await auth.waitForApproval(pair) }
        try await Task.sleep(for: .seconds(2.5))
        poll.cancel()
        // Still waiting (no approval) means both the request and the v2 poll shape were accepted.
        await #expect(throws: CancellationError.self) { try await poll.value }
    }
}

/// Creates a real account: `HAPPIER_LIVE_SERVER=… HAPPIER_LIVE_CREATE_ACCOUNT=1 swift test --filter LiveAccountCreationTests`.
/// Opt-in on its own, since every run leaves a new (empty) account on that relay.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HAPPIER_LIVE_SERVER"] != nil
                && ProcessInfo.processInfo.environment["HAPPIER_LIVE_CREATE_ACCOUNT"] == "1"))
struct LiveAccountCreationTests {
    let server = URL(string: ProcessInfo.processInfo.environment["HAPPIER_LIVE_SERVER"] ?? "https://api.happier.dev")!

    @Test func aNewDeviceKeyAccountCanBeLinkedAndKeepsItsSettings() async throws {
        let auth = AuthAPI(server: server)
        let options = try await auth.options()
        try #require(options.canCreateAccount, "this relay doesn't accept new accounts")
        let created = try await auth.createAccount(publishContentKey: options.publishesContentKey)
        let accountId = try #require(created.credentials.accountId)
        print("live account: \(accountId) on \(server.absoluteString)")

        // The same secret signs in again to the same account instead of creating another.
        #expect(try await auth.signIn(secret: created.secret).accountId == accountId)

        // Another device of this account would trust these keys before linking (Link New Device).
        let api = HappierAPI(server: server, token: created.credentials.token)
        let encrypted = try await api.accountIsEncrypted()
        let profile = try #require(try await api.accountLinkProfile(accountId: accountId))
        if options.publishesContentKey { #expect(profile.contentPublicKey != nil && profile.contentPublicKeySig != nil) }
        try AccountKeyProvisioning.verify(encrypted: encrypted, account: profile, credentials: created.credentials)

        // Settings: empty, written in the shared format, read back, and a stale write is a conflict.
        let keys = try created.credentials.accountKeys()
        let empty = try await api.accountSettings()
        #expect(AccountSettingsContent.open(empty.content, keys: keys) == [:])
        var settings = AccountSettings(values: [:])
        var notifications = settings.notifications
        notifications.permissionRequest = false
        settings = settings.merging(settings.delta(notifications: notifications))
        let sealed = try AccountSettingsContent.seal(settings.values, keys: keys, plain: !encrypted)
        guard case .saved(let version) = try await api.writeAccountSettings(sealed, expectedVersion: empty.version) else {
            Issue.record("first write wasn't saved")
            return
        }
        let reread = try await api.accountSettings()
        #expect(reread.version == version)
        #expect(AccountSettingsContent.open(reread.content, keys: keys).map(AccountSettings.init(values:))?.notifications.permissionRequest == false)
        guard case .conflict(let current, let content) = try await api.writeAccountSettings(sealed, expectedVersion: empty.version) else {
            Issue.record("a stale write wasn't refused")
            return
        }
        #expect(current == version && AccountSettingsContent.open(content, keys: keys) == settings.values)
    }
}

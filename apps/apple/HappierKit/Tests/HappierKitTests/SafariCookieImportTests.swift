import Foundation
import Testing
#if canImport(WebKit)
import WebKit
#endif
@testable import HappierKit

struct SafariCookieImportTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func message(_ changes: [String: Any] = [:], origin: String = "https://login.example.com") throws -> Data {
        var cookie: [String: Any] = ["name": "session", "value": "synthetic-fixture", "domain": "login.example.com",
            "path": "/account", "secure": true, "httpOnly": true, "hostOnly": true,
            "session": false, "expirationDate": now.timeIntervalSince1970 + 3600, "sameSite": "strict"]
        cookie.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: ["version": 1, "origin": origin, "cookies": [cookie]])
    }

    @Test func retainsAuthenticationCookieScopeAndSecurityAttributes() throws {
        let transfer = try SafariCookieImport.prepare(message: message(), now: now)
        let cookie = try #require(transfer.httpCookies(now: now).first)
        #expect(cookie.name == "session")
        #expect(cookie.value == "synthetic-fixture")
        #expect(cookie.domain == "login.example.com")
        #expect(cookie.path == "/account")
        #expect(cookie.isSecure && cookie.isHTTPOnly)
        #expect(cookie.sameSitePolicy?.rawValue == "strict")
        #expect(cookie.expiresDate == now.addingTimeInterval(3600))
        #expect(!cookie.isSessionOnly)

        let scoped = try SafariCookieImport.prepare(message: message(["domain": ".example.com", "hostOnly": false,
            "session": true, "expirationDate": NSNull(), "sameSite": "no_restriction"]), now: now)
        let domainCookie = try #require(scoped.httpCookies(now: now).first)
        #expect(domainCookie.domain == ".example.com")
        #expect(domainCookie.isSessionOnly)
        #expect(domainCookie.sameSitePolicy?.rawValue == "none")
    }

    @Test func rejectsCrossSiteInjectionExpiredAndPartitionedCookies() throws {
        for change: [String: Any] in [
            ["domain": "other.example.com"], ["domain": ".evil.com", "hostOnly": false],
            ["name": "session\r\nSet-Cookie"], ["value": "x\r\nX-Injected: y"],
            ["path": "/; Secure"], ["expirationDate": now.timeIntervalSince1970 - 1],
            ["partitionKey": ["topLevelSite": "https://example.com"]], ["partitioned": true],
            ["sameSite": "no_restriction", "secure": false], ["sameSite": "unknown"], ["sameSite": "unspecified"],
            ["name": "__Host-session", "path": "/account"],
        ] {
            #expect(throws: SafariCookieImport.Failure.self) {
                try SafariCookieImport.prepare(message: message(change), now: now)
            }
        }
        #expect(throws: SafariCookieImport.Failure.self) {
            try SafariCookieImport.prepare(message: message(origin: "https://user:secret@login.example.com/path?token=hidden"), now: now)
        }
    }
    @Test func localHandoffExpiresAndIsRemovedAfterReview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cookie-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SafariCookieInbox(root: root)
        let transfer = try SafariCookieImport.prepare(message: message(), now: now)
        try inbox.save(transfer, now: now)
        #expect(try inbox.load(transfer.id, now: now).cookies.count == 1)
        let file = root.appendingPathComponent(transfer.id.uuidString + ".json")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        try inbox.remove(transfer.id)
        #expect(inbox.pending(now: now).isEmpty)
        try inbox.save(transfer, now: now)
        #expect(inbox.pending(now: now.addingTimeInterval(SafariCookieImport.lifetime)).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    #if canImport(WebKit)
    @MainActor @Test func webKitKeepsTheConvertedCookieAttributes() async throws {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let store = dataStore.httpCookieStore
        for changes: [String: Any] in [
            [:],
            ["name": "domain", "domain": ".example.com", "hostOnly": false,
             "session": true, "expirationDate": NSNull(), "sameSite": "no_restriction"],
            ["name": "lax", "sameSite": "lax"],
        ] {
            let transfer = try SafariCookieImport.prepare(message: message(changes), now: now)
            let expected = try #require(transfer.httpCookies(now: now).first)
            await store.setCookie(expected)
            let actual = try #require(await store.allCookies().first { $0.name == expected.name })
            #expect(actual.domain == expected.domain)
            #expect(actual.path == expected.path)
            #expect(actual.value == expected.value)
            #expect(actual.isSecure && actual.isHTTPOnly)
            #expect(actual.sameSitePolicy == expected.sameSitePolicy)
            #expect(actual.expiresDate == expected.expiresDate)
            #expect(actual.isSessionOnly == expected.isSessionOnly)
        }
    }
    #endif

}

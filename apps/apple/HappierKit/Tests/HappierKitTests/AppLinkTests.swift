import Foundation
import Testing
@testable import HappierKit

@Suite struct AppLinkTests {
    @Test(arguments: [
        "https://github.com/login?return_to=%2Fsettings%2Fsecurity",
        "http://localhost:3000/preview#section",
        "https://happier.nomada.cloud/",
    ]) func ordinaryWebsitesOpenInBrowser(_ address: String) {
        #expect(AppLink(url: URL(string: address)!) == .website)
    }

    @Test func sessionLinksKeepTheirNativeDestination() throws {
        let link = try #require(SessionLink(sessionId: "session-1", server: URL(string: "https://relay.example")!))
        #expect(AppLink(url: link.webURL) == .session)
        #expect(AppLink(url: link.nativeURL) == .session)
        #expect(AppLink(url: URL(string: "happier-native://inbox")!) == .inbox)
        #expect(AppLink(url: URL(string: "happier-native://new")!) == .newSession)
        #expect(AppLink(url: URL(string: "happier-native://share")!) == .share)
    }

    @Test func browserRoleLoadsSessionLandingPageBeforeOpeningNativeLink() throws {
        let link = try #require(SessionLink(sessionId: "session-1", server: URL(string: "https://relay.example")!))
        #expect(AppLink(url: link.webURL, isBrowserRole: true) == .website)
        #expect(AppLink(url: link.nativeURL, isBrowserRole: true) == .session)
    }

    @Test func malformedNativeSessionStillReachesSessionValidation() {
        let url = URL(string: "happier-native://session/id?server=file:///tmp/relay")!
        #expect(AppLink(url: url) == .session)
        #expect(SessionLink(url: url) == nil)
    }

    @Test(arguments: ["file:///tmp/test.html", "javascript:alert(1)", "data:text/html,test", "https:/no-host", "http:/no-host", "other://session/id"])
    func unsupportedURLsDoNotOpenInBrowser(_ address: String) {
        #expect(AppLink(url: URL(string: address)!) == nil)
    }
}

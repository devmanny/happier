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
        #expect(AppLink(url: DictationKeyboard.openURL) == .keyboardDictation)
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
    // Which links the system delivers is the app's registration, not this: only `happier-native`
    // and, in the browser builds, the web link reach the app today (see README, Connect a computer).
    @Test(arguments: [false, true]) func computerSignInLinksResolveToTheApproval(_ browserRole: Bool) {
        let params = "key=V9tLNZ8jrl4Ubk4lEgVnBHIlBjSMFQwUdT0Mkz0E1CE&server=https%3A%2F%2Frelay.example.com&pairingSecret=CwsL&createdAt=1&expiresAt=2"
        for address in ["https://happier.nomada.cloud/terminal/connect#\(params)", "happier-native://terminal?\(params)", "happier://terminal?\(params)"] {
            #expect(AppLink(url: URL(string: address)!, isBrowserRole: browserRole) == .terminalConnect)
        }
        // Without a key it's an ordinary page (or session-link validation for the native scheme).
        #expect(AppLink(url: URL(string: "https://happier.nomada.cloud/terminal/connect")!, isBrowserRole: browserRole) == .website)
        #expect(AppLink(url: URL(string: "happier-native://terminal")!, isBrowserRole: browserRole) == .session)
    }

    @Test func safariImportLinksContainOnlyATransferID() {
        let id = UUID()
        #expect(AppLink(url: URL(string: "happier-native://browser-import/\(id)")!) == .browserImport(id))
        for suffix in ["/../file", "/not-a-uuid", "/\(id)?value=secret", "/\(id)#secret"] {
            #expect(AppLink(url: URL(string: "happier-native://browser-import" + suffix)!) == nil)
        }
    }

}

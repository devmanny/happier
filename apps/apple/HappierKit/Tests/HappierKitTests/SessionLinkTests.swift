import Foundation
import Testing
@testable import HappierKit

@Suite struct SessionLinkTests {
    let server = URL(string: "https://relay.example.test/base")!
    @Test func publicAndNativeLinksRoundTripWithoutCredentials() throws {
        let link = try #require(SessionLink(sessionId: "c-session_1", server: server))
        #expect(link.webURL.absoluteString.hasPrefix("https://happier.nomada.cloud/native/index.html?"))
        #expect(link.nativeURL.absoluteString.hasPrefix("happier-native://session/c-session_1?"))
        #expect(SessionLink(url: link.webURL) == link)
        #expect(SessionLink(url: link.nativeURL) == link)
        let query = URLComponents(url: link.webURL, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first { $0.name == "server" }?.value == server.absoluteString)
        #expect(query?.first { $0.name == "session" }?.value == "c-session_1")
    }
    @Test func relayRepresentationPreservesSavedCredentialKey() throws {
        let address = URL(string: "https://Relay.Example:443/Path")!
        let link = try #require(SessionLink(sessionId: "saved", server: address))
        #expect(link.server.absoluteString == address.absoluteString)
        #expect(SessionLink(url: link.webURL)?.server == address)
        #expect(SessionLink(url: link.nativeURL)?.server == address)
    }
    @Test func plusAndOpaqueCharactersUseFormCompatibleQueryEncoding() throws {
        let link = try #require(SessionLink(sessionId: "session+plus:opaque", server: URL(string: "https://relay.example.test/path+plus")!))
        #expect(URLComponents(url: link.webURL, resolvingAgainstBaseURL: false)?.percentEncodedQuery?.contains("+") == false)
        #expect(URLComponents(url: link.nativeURL, resolvingAgainstBaseURL: false)?.percentEncodedQuery?.contains("+") == false)
        print("CANONICAL_PLUS_WEB_URL " + link.webURL.absoluteString)
        #expect(SessionLink(url: link.webURL) == link)
        #expect(SessionLink(url: link.nativeURL) == link)
        #expect(SessionLink(url: URL(string: "https://happier.nomada.cloud/native/index.html?session=raw+space&server=https://relay.example.test")!) == nil)
    }
    @Test(arguments: ["a?b", "a#b", "a%b", ".", ".."])
    func unsafeOpaqueIDsAreNotSerialized(_ id: String) {
        #expect(SessionLink(sessionId: id, server: server) == nil)
    }
    @Test(arguments: ["http://localhost:8807", "http://127.0.0.1:8807", "http://[::1]:8807"])
    func loopbackRelayIsSupported(_ address: String) throws {
        let link = try #require(SessionLink(sessionId: "test-session", server: URL(string: address)!))
        #expect(SessionLink(url: link.nativeURL) == link)
    }
    @Test(arguments: [
        "https://evil.example/native/index.html?session=a&server=https://relay.example",
        "https://happier.nomada.cloud/other?session=a&server=https://relay.example",
        "happier://session/a?server=https://relay.example",
        "happier-native://session/a/b?server=https://relay.example",
        "happier-native://session/%2F?server=https://relay.example",
        "happier-native://session/..?server=https://relay.example",
        "happier-native://session/a?serverId=relay-id",
        "happier-native://session/a?server=https://relay.example&server=https://other.example",
        "https://happier.nomada.cloud/native/index.html?session=a&session=b&server=https://relay.example",
        "happier-native://session/a?server=https://user:pass@relay.example",
        "happier-native://session/a?server=https://relay.example%3Ftoken%3Dprivate",
        "happier-native://session/a?server=https://relay.example%23fragment",
        "happier-native://session/a?server=http://relay.example",
        "happier-native://session/a?server=http://127.0.0.1.evil.test",
        "happier-native://session/a?server=http://127.0.0.2",
        "happier-native://session/a?server=https://relay.example/base%5Cpath",
        "happier-native://session/a?server=file:///tmp/relay",
        "happier-native://session/a?server=relay.example",
        "happier-native://session/a?server=https://relay.example#fragment"
    ]) func malformedOrUntrustedLinksDoNotBecomeDestinations(_ text: String) {
        #expect(SessionLink(url: URL(string: text)!) == nil)
    }
}

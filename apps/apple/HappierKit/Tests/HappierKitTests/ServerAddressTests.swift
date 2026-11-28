import Foundation
import Testing
@testable import HappierKit

@Suite struct ServerAddressTests {
    @Test func acceptsBareHostsAndFullURLs() {
        #expect(ServerAddress.normalize("happier.nomada.cloud")?.absoluteString == "https://happier.nomada.cloud")
        #expect(ServerAddress.normalize("  https://happier.nomada.cloud/ ")?.absoluteString == "https://happier.nomada.cloud")
        #expect(ServerAddress.normalize("http://192.168.1.10:3005")?.absoluteString == "http://192.168.1.10:3005")
        #expect(ServerAddress.normalize("localhost:3005")?.absoluteString == "https://localhost:3005")
    }

    @Test func rejectsGarbage() {
        #expect(ServerAddress.normalize("") == nil)
        #expect(ServerAddress.normalize("not a url") == nil)
        #expect(ServerAddress.normalize("ftp://x.com") == nil)
    }
}

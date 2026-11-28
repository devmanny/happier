import Foundation
import Testing
@testable import HappierKit

@Suite struct RelayListTests {
    @Test func remembersEachRelayOnceWhateverTheSpelling() {
        let nomada = URL(string: "https://happier.nomada.cloud")!
        var list = RelayList.adding(nomada, to: [])
        list = RelayList.adding(URL(string: "https://happier.nomada.cloud/")!, to: list)
        list = RelayList.adding(URL(string: "https://api.happier.dev")!, to: list)
        #expect(list.map(\.absoluteString) == ["https://happier.nomada.cloud", "https://api.happier.dev"])
    }

    @Test func oneRelayWhateverTheCaseOfItsHostOrItsDefaultPort() {
        let nomada = URL(string: "https://happier.nomada.cloud")!
        #expect(RelayList.canonical(URL(string: "https://Happier.Nomada.cloud:443/")!) == RelayList.canonical(nomada))
        #expect(RelayList.canonical(URL(string: "HTTP://LocalHost:80")!) == RelayList.canonical(URL(string: "http://localhost")!))
        #expect(RelayList.canonical(URL(string: "https://relay.example:8443")!) != RelayList.canonical(URL(string: "https://relay.example")!))
        #expect(RelayList.canonical(URL(string: "http://relay.example")!) != RelayList.canonical(URL(string: "https://relay.example")!))
        #expect(RelayList.canonical(URL(string: "https://relay.example/A")!) != RelayList.canonical(URL(string: "https://relay.example/a")!))
        // A remembered relay keeps the spelling its sign-in is saved under (the Keychain item's name).
        let saved = URL(string: "https://Relay.Example:443/Path")!
        #expect(RelayList.adding(saved, to: []) == [saved])
        #expect(RelayList.adding(URL(string: "https://relay.example/Path/")!, to: [saved]) == [saved])
    }

    @Test func readsTheServerBuildFromItsVersionRoute() {
        #expect(RelayList.build(fromVersion: ["ok": true, "source_sha": "463b3029aede2a5c137bafd081e1af27f29d0c02"]) == "463b302")
        #expect(RelayList.build(fromVersion: ["ok": true]) == nil)
    }
}

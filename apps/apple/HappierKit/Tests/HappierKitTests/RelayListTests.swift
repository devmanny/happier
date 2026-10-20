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

    @Test func readsTheServerBuildFromItsVersionRoute() {
        #expect(RelayList.build(fromVersion: ["ok": true, "source_sha": "463b3029aede2a5c137bafd081e1af27f29d0c02"]) == "463b302")
        #expect(RelayList.build(fromVersion: ["ok": true]) == nil)
    }
}

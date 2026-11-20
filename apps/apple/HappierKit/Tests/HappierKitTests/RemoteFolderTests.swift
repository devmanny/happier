import Testing
@testable import HappierKit

/// Machine folder browser (`machineFileBrowser.ts`, `daemon.filesystem.listDirectory`).
@Suite struct RemoteFolderTests {
    @Test func listsOnlyDirectoriesSortedWithHiddenLast() throws {
        let response: JSONValue = ["ok": true, "path": "/Users/m", "truncated": false, "entries": [
            ["name": "zeta", "path": "/Users/m/zeta", "type": "directory"],
            ["name": "notes.txt", "path": "/Users/m/notes.txt", "type": "file"],
            ["name": ".config", "path": "/Users/m/.config", "type": "directory"],
            ["name": "Alpha", "path": "/Users/m/Alpha", "type": "directory"],
        ]]
        let listing = try RemoteFolder.listing(from: response)
        #expect(listing.folders.map(\.name) == ["Alpha", "zeta", ".config"])
        #expect(listing.folders.last?.isHidden == true)
        #expect(!listing.truncated)
    }

    @Test func surfacesDaemonErrors() {
        #expect(throws: (any Error).self) { try RemoteFolder.listing(from: ["ok": false, "error": "Access denied"]) }
    }

    @Test func joinsPathsForThePlatform() {
        #expect(RemoteFolder.join("/Users/m/", "new", platform: "darwin") == "/Users/m/new")
        #expect(RemoteFolder.join(#"C:\Users\m"#, "new", platform: "win32") == #"C:\Users\m\new"#)
    }
}

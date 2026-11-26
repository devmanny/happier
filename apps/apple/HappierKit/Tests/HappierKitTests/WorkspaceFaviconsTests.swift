import Foundation
import Testing
@testable import HappierKit

/// A project's favicon on its sessions: asked of the computer once per folder, kept on disk for
/// the next launch, dropped when the folder no longer has one, and asked again later when the
/// computer couldn't be reached.
@MainActor
@Suite struct WorkspaceFaviconsTests {
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    private func found(_ data: Data, _ mime: String = "image/png") -> JSONValue {
        ["success": true, "found": true, "relativePath": "public/favicon.png", "mimeType": .string(mime),
         "contentBase64": .string(data.base64EncodedString()), "sizeBytes": .number(Double(data.count))]
    }

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "favicons-\(UUID().uuidString)")
    }

    @Test func aFoundIconIsAskedForOnceAndKeptForTheNextLaunch() async {
        let directory = folder()
        var asked = 0
        let favicons = WorkspaceFavicons(directory: directory) { machineId, method, params in
            asked += 1
            #expect(machineId == "mac")
            #expect(method == "workspace.favicon.resolve")
            #expect(params["workspacePath"]?.stringValue == "/p/radar")
            return found(png)
        }
        // The first look asks; the answer arrives later.
        #expect(favicons.icon(machineId: "mac", path: "/p/radar") == nil)
        for _ in 0..<50 where favicons.icons.isEmpty { await Task.yield() }
        #expect(favicons.icon(machineId: "mac", path: "/p/radar") == .init(data: png, mimeType: "image/png"))
        // Later looks (every redraw of the list) don't ask again.
        for _ in 0..<20 { await Task.yield() }
        #expect(asked == 1)

        // Next launch: shown from disk before the computer answers.
        let next = WorkspaceFavicons(directory: directory) { _, _, _ in throw URLError(.notConnectedToInternet) }
        #expect(next.icon(machineId: "mac", path: "/p/radar") == .init(data: png, mimeType: "image/png"))
    }

    @Test func aFolderThatNoLongerHasAnIconLosesIt() async {
        let directory = folder()
        var answer = found(png)
        let favicons = WorkspaceFavicons(directory: directory) { _, _, _ in answer }
        await favicons.ask(machineId: "mac", path: "/p/radar")
        answer = ["success": true, "found": false]
        await favicons.ask(machineId: "mac", path: "/p/radar")
        #expect(favicons.icons.isEmpty)
        let next = WorkspaceFavicons(directory: directory) { _, _, _ in throw URLError(.notConnectedToInternet) }
        #expect(next.icon(machineId: "mac", path: "/p/radar") == nil)
    }

    @Test func anUnreachableComputerKeepsWhatWasShownAndIsAskedAgainLater() async {
        let directory = folder()
        var reachable = true
        var asked = 0
        let favicons = WorkspaceFavicons(directory: directory, retryDelay: 0) { _, _, _ in
            asked += 1
            guard reachable else { throw URLError(.notConnectedToInternet) }
            return found(png)
        }
        await favicons.ask(machineId: "mac", path: "/p/radar")
        reachable = false
        await favicons.ask(machineId: "mac", path: "/p/radar")
        #expect(favicons.icons.count == 1)
        // A failed ask makes the folder due again (here at once).
        let before = asked
        _ = favicons.icon(machineId: "mac", path: "/p/radar")
        await Task.yield()
        for _ in 0..<20 where asked == before { await Task.yield() }
        #expect(asked == before + 1)
    }

    @Test func anIconIsPreparedForThisDeviceOnlyWhenTheComputerSendsADifferentOne() async {
        let directory = folder()
        let svg = Data("<svg/>".utf8)
        var sent = svg
        var prepared = 0
        let favicons = WorkspaceFavicons(directory: directory) { _, _, _ in found(sent, "image/svg+xml") }
        // As on the iPhone: an SVG is drawn to a PNG first.
        favicons.prepare = { _ in prepared += 1; return .init(data: png, mimeType: "image/png") }
        await favicons.ask(machineId: "mac", path: "/p/radar")
        await favicons.ask(machineId: "mac", path: "/p/radar")
        #expect(prepared == 1)
        #expect(favicons.icons.first?.value == .init(data: png, mimeType: "image/png"))

        // Next launch: the same SVG isn't drawn again; a changed one is.
        let next = WorkspaceFavicons(directory: directory) { _, _, _ in found(sent, "image/svg+xml") }
        next.prepare = { _ in prepared += 1; return .init(data: png, mimeType: "image/png") }
        await next.ask(machineId: "mac", path: "/p/radar")
        #expect(prepared == 1)
        sent = Data("<svg><rect/></svg>".utf8)
        await next.ask(machineId: "mac", path: "/p/radar")
        #expect(prepared == 2)
    }

    @Test func refusedOrMalformedAnswersCarryNoIcon() {
        #expect(WorkspaceFavicons.icon(from: ["success": false, "errorCode": "INVALID_WORKSPACE_PATH", "error": "no"]) == nil)
        #expect(WorkspaceFavicons.icon(from: ["success": true, "found": false]) == nil)
        #expect(WorkspaceFavicons.icon(from: ["success": true, "found": true, "mimeType": "image/png", "contentBase64": "%%%"]) == nil)
        #expect(WorkspaceFavicons.icon(from: found(png, "image/svg+xml"))?.mimeType == "image/svg+xml")
    }
}

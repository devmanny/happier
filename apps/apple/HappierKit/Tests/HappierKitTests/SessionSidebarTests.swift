import Foundation
import Testing
@testable import HappierKit

/// The sidebar shows pinned and running conversations; stopped ones wait in a collapsed group.
@Suite struct SessionSidebarTests {
    private func session(_ id: String, active: Bool, at: Double, parent: String? = nil, title: String = "t", path: String = "/a") throws -> Session {
        let spawned = parent.map { #","spawnedBySessionV1":{"parentSessionId":"\#($0)"}"# } ?? ""
        let metadata = #"{"path":"\#(path)","name":"\#(title)"\#(spawned)}"#
        return try Session(row: ["id": .string(id), "encryptionMode": "plain", "metadata": .string(metadata), "metadataVersion": 1,
                                 "active": .bool(active), "updatedAt": .number(at)], keys: nil)
    }

    private func ids(_ nodes: [SessionTreeNode<Session>]) -> [String] {
        nodes.map { node in
            guard let children = node.children else { return node.id }
            return "\(node.id)(\(ids(children).joined(separator: ",")))"
        }
    }

    @Test func splitsPinnedRunningAndStopped() throws {
        let groups = SessionSidebar.groups([
            try session("run", active: true, at: 30),
            try session("stopped", active: false, at: 40),
            try session("pinnedStopped", active: false, at: 10),
            try session("old", active: false, at: 5),
        ], pinned: ["pinnedStopped"])
        #expect(ids(groups.pinned) == ["pinnedStopped"])
        #expect(ids(groups.active) == ["run"])
        #expect(ids(groups.inactive) == ["stopped", "old"])
    }

    @Test func aRunningChildKeepsItsFamilyInTheMainList() throws {
        let groups = SessionSidebar.groups([
            try session("parent", active: false, at: 10),
            try session("child", active: true, at: 20, parent: "parent"),
            try session("done", active: false, at: 30),
        ], pinned: [])
        #expect(ids(groups.active) == ["parent(child)"])
        #expect(ids(groups.inactive) == ["done"])
    }

    @Test func familiesRiseWithTheirLatestActivityPinnedOrNot() throws {
        // A message in a child (or the parent) brings the whole family to the top of its section.
        let groups = SessionSidebar.groups([
            try session("pinnedOld", active: true, at: 10),
            try session("pinnedNew", active: true, at: 20),
            try session("busyChild", active: true, at: 50, parent: "pinnedOld"),
            try session("quiet", active: true, at: 30),
            try session("loud", active: true, at: 5),
            try session("loudChild", active: true, at: 60, parent: "loud"),
        ], pinned: ["pinnedNew", "pinnedOld"])
        #expect(ids(groups.pinned) == ["pinnedOld(busyChild)", "pinnedNew"])
        #expect(ids(groups.active) == ["loud(loudChild)", "quiet"])
    }

    @Test func aPinnedSessionStaysInPinnedWhenTheFilterLeavesItOut() throws {
        // Pinning is explicit: the filter (no task sessions by default) shapes the rest of the list.
        let hidden: Set<String> = ["pinnedTask", "task", "taskChild"]
        let groups = SessionSidebar.groups([
            try session("pinnedTask", active: false, at: 10),
            try session("taskChild", active: true, at: 15, parent: "pinnedTask"),
            try session("task", active: true, at: 20),
            try session("run", active: true, at: 30),
        ], pinned: ["pinnedTask"], shows: { !hidden.contains($0.id) })
        #expect(ids(groups.pinned) == ["pinnedTask"])
        #expect(ids(groups.active) == ["run"])
        #expect(ids(groups.inactive).isEmpty)
    }

    @Test func searchMatchesTitleAndFolder() throws {
        let s = try session("s", active: false, at: 1, title: "Facturación de octubre", path: "/Users/m/Projects/kelpi")
        #expect(s.matches("FACTURA"))
        #expect(s.matches("kelpi"))
        #expect(!s.matches("growy"))
    }
}

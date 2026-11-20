import Foundation
import Testing
@testable import HappierKit

/// Children are sessions started from inside another session (`spawnedBySessionV1`); forks are not.
@Suite struct SessionTreeTests {
    struct Item: Identifiable, Equatable {
        let id: String
        let parent: String?
        let at: Double
    }

    private func build(_ items: [Item]) -> [SessionTreeNode<Item>] {
        SessionTree.build(items, parent: \.parent, date: { Date(timeIntervalSince1970: $0.at) })
    }

    private func shape(_ nodes: [SessionTreeNode<Item>]) -> [String] {
        nodes.map { node in
            guard let children = node.children else { return node.id }
            return "\(node.id)(\(shape(children).joined(separator: ",")))"
        }
    }

    @Test func nestsChildrenUnderTheSessionThatStartedThem() {
        let nodes = build([
            Item(id: "a", parent: nil, at: 10),
            Item(id: "a1", parent: "a", at: 5),
            Item(id: "a2", parent: "a", at: 7),
            Item(id: "a2x", parent: "a2", at: 1),
            Item(id: "b", parent: nil, at: 8),
        ])
        #expect(shape(nodes) == ["a(a2(a2x),a1)", "b"])
    }

    @Test func aBusyChildBringsItsParentUp() {
        let nodes = build([
            Item(id: "a", parent: nil, at: 1),
            Item(id: "a1", parent: "a", at: 20),
            Item(id: "b", parent: nil, at: 10),
        ])
        #expect(shape(nodes) == ["a(a1)", "b"])
    }

    @Test func childrenOfMissingParentsAndCyclesStayVisible() {
        let nodes = build([
            Item(id: "orphan", parent: "archived-parent", at: 3),
            Item(id: "x", parent: "y", at: 2),
            Item(id: "y", parent: "x", at: 1),
        ])
        #expect(shape(nodes).first == "orphan")
        func ids(_ nodes: [SessionTreeNode<Item>]) -> [String] { nodes.flatMap { [$0.id] + ids($0.children ?? []) } }
        #expect(ids(nodes).sorted() == ["orphan", "x", "y"])
    }
}

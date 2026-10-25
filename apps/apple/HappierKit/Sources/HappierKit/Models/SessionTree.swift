import Foundation

/// A session and the sessions started from inside it (`children` is nil for a leaf, as
/// `OutlineGroup`/`List(children:)` expect).
public struct SessionTreeNode<Item: Identifiable>: Identifiable where Item.ID == String {
    public let item: Item
    public var children: [SessionTreeNode]?
    public var id: String { item.id }
}

public enum SessionTree {
    /// Whether `child` can be moved under `parent`: not under itself, nor under a session nested
    /// (at any depth) inside it, which would make a loop.
    public static func canNest(_ child: String, under parent: String, parent parentOf: (String) -> String?) -> Bool {
        var current: String? = parent
        var seen = Set<String>()
        while let id = current, seen.insert(id).inserted {
            if id == child { return false }
            current = parentOf(id)
        }
        return true
    }

    /// The deepest folder two paths share, where a session grouping both can start; nil when they
    /// share only the root of the disk.
    public static func sharedFolder(_ first: String, _ second: String) -> String? {
        let windows = first.contains("\\") && !first.contains("/")
        func parts(_ path: String) -> [String] { path.components(separatedBy: CharacterSet(charactersIn: "/\\")) }
        var shared: [String] = []
        for (a, b) in zip(parts(first), parts(second)) {
            guard a == b else { break }
            shared.append(a)
        }
        // "/" alone or a bare drive ("C:") is the disk itself.
        guard shared.filter({ !$0.isEmpty }).count >= (windows ? 2 : 1) else { return nil }
        return shared.joined(separator: windows ? "\\" : "/")
    }

    /// Nests each item under its parent when the parent is in `items`. Siblings are ordered by
    /// the latest activity in their subtree, so a busy child brings its parent up.
    public static func build<Item: Identifiable>(
        _ items: [Item], parent: (Item) -> String?, date: (Item) -> Date
    ) -> [SessionTreeNode<Item>] where Item.ID == String {
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var childrenOf: [String: [Item]] = [:]
        var roots: [Item] = []
        for item in items {
            if let parentId = parent(item), parentId != item.id, byId[parentId] != nil {
                childrenOf[parentId, default: []].append(item)
            } else {
                roots.append(item)
            }
        }
        var placed = Set<String>()
        func node(_ item: Item) -> (SessionTreeNode<Item>, Date) {
            placed.insert(item.id)
            var latest = date(item)
            let children = (childrenOf[item.id] ?? []).filter { !placed.contains($0.id) }.map(node)
            for (_, childDate) in children { latest = max(latest, childDate) }
            let sorted = children.sorted { $0.1 > $1.1 }.map(\.0)
            return (SessionTreeNode(item: item, children: sorted.isEmpty ? nil : sorted), latest)
        }
        var built = roots.map(node)
        // Items caught in a parent cycle are unreachable from any root; show them at the top level.
        for item in items where !placed.contains(item.id) { built.append(node(item)) }
        return built.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

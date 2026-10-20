import Foundation

/// Pinned conversations: the account's session organization pins (`/v2/session-organization`),
/// the same ones the official app shows at the top of its list.
public enum SessionPins {
    /// Pin order from `projection.ts`: explicit sort keys first, then when they were pinned.
    public static func orderedIds(fromSnapshot response: JSONValue) -> [String] {
        let pins = response["snapshot"]?["pins"]?.arrayValue ?? []
        return pins.compactMap { pin -> (id: String, sortKey: String?, pinnedAt: Double)? in
            guard let id = pin["sessionId"]?.stringValue else { return nil }
            return (id, pin["sortKey"]?.stringValue, pin["pinnedAt"]?.doubleValue ?? 0)
        }
        .sorted { a, b in
            switch (a.sortKey, b.sortKey) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return (a.pinnedAt, a.id) < (b.pinnedAt, b.id)
            }
        }
        .map(\.id)
    }

    /// `items` with the pinned ones first, in pin order; the rest keep their order.
    public static func pinnedFirst<Item>(_ items: [Item], pinned: [String], id: (Item) -> String) -> [Item] {
        let rank = Dictionary(pinned.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let pinnedItems = items.filter { rank[id($0)] != nil }.sorted { rank[id($0)]! < rank[id($1)]! }
        return pinnedItems + items.filter { rank[id($0)] == nil }
    }
}

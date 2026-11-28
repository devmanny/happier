import Foundation

/// Results of a pure function of a text (Markdown parsing), kept so a view built again for the
/// same text (every redraw of a conversation) doesn't parse it again. Bounded, and emptied by the
/// system under memory pressure (`NSCache`).
public final class TextCache<Value>: @unchecked Sendable {
    private final class Box { let value: Value; init(_ value: Value) { self.value = value } }
    private let cache = NSCache<NSString, Box>()

    public init(limit: Int = 500) {
        cache.countLimit = limit
    }

    public func value(for text: String, make: (String) -> Value) -> Value {
        if let hit = cache.object(forKey: text as NSString) { return hit.value }
        let value = make(text)
        cache.setObject(Box(value), forKey: text as NSString)
        return value
    }
}

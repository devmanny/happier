import Foundation

/// Pages the user visited in the integrated browser, one entry per page, and what to suggest
/// while an address is typed. It lives only on this device (the app saves it as a file).
public struct BrowserHistory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let url: URL
        public var title: String
        public var visitCount: Int
        public var lastVisited: Date
    }

    /// Pages not visited for a year are forgotten, as Safari does by default.
    public static let retention: TimeInterval = 365 * 24 * 60 * 60

    public private(set) var entries: [Entry] = []

    public init() {}

    /// A finished page load. Only web pages count; a URL's #fragment is the same page.
    public mutating func recordVisit(url: URL, title: String, at date: Date) {
        guard let page = Self.page(url) else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = entries.firstIndex(where: { $0.url == page }) {
            entries[index].visitCount += 1
            entries[index].lastVisited = date
            if !title.isEmpty { entries[index].title = title }
        } else {
            entries.append(Entry(url: page, title: title, visitCount: 1, lastVisited: date))
        }
    }

    public mutating func removeExpired(now: Date) {
        entries.removeAll { now.timeIntervalSince($0.lastVisited) > Self.retention }
    }

    /// Visited pages matching what was typed: sites whose name starts with it, then pages whose
    /// address continues it, then pages whose address or title mention it; within each, the more
    /// visited and then the more recent first.
    public func suggestions(for typed: String, limit: Int) -> [Entry] {
        let query = Self.withoutSchemeAndWWW(typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        guard !query.isEmpty, limit > 0 else { return [] }
        let ranked: [(rank: Int, entry: Entry)] = entries.compactMap { entry in
            let address = Self.withoutSchemeAndWWW(entry.url.absoluteString.lowercased())
            let host = Self.withoutSchemeAndWWW(entry.url.host()?.lowercased() ?? "")
            if host.hasPrefix(query) { return (0, entry) }
            if address.hasPrefix(query) { return (1, entry) }
            if address.contains(query) || entry.title.lowercased().contains(query) { return (2, entry) }
            return nil
        }
        return ranked
            .sorted { a, b in
                if a.rank != b.rank { return a.rank < b.rank }
                if a.entry.visitCount != b.entry.visitCount { return a.entry.visitCount > b.entry.visitCount }
                return a.entry.lastVisited > b.entry.lastVisited
            }
            .prefix(limit)
            .map(\.entry)
    }

    private static func page(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.isEmpty == false else { return nil }
        components.fragment = nil
        return components.url
    }

    private static func withoutSchemeAndWWW(_ text: String) -> String {
        var text = Substring(text)
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) { text = text.dropFirst(prefix.count) }
        if text.hasPrefix("www.") { text = text.dropFirst(4) }
        return String(text)
    }
}

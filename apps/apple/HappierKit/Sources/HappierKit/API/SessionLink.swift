import Foundation

/// Public links identify a session and relay; they never carry account credentials.
public struct SessionLink: Equatable, Sendable {
    public let sessionId: String
    public let server: URL

    public init?(sessionId: String, server: URL) {
        guard Self.validID(sessionId), let server = Self.relay(server.absoluteString) else { return nil }
        self.sessionId = sessionId
        self.server = server
    }

    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.fragment == nil else { return nil }
        // The landing page uses URLSearchParams: a raw '+' is a space, '%2B' is a plus.
        var query = parts
        query.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
        guard let items = query.queryItems, Set(items.map(\.name)).count == items.count else { return nil }
        let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        let id: String
        switch (parts.scheme?.lowercased(), parts.host?.lowercased()) {
        case ("https", "happier.nomada.cloud"):
            guard parts.port == nil || parts.port == 443,
                  parts.path == "/native/index.html", Set(fields.keys) == ["session", "server"],
                  let session = fields["session"] else { return nil }
            id = session
        case ("happier-native", "session"):
            guard parts.port == nil, Set(fields.keys) == ["server"], parts.path.hasPrefix("/") else { return nil }
            id = String(parts.path.dropFirst())
        default: return nil
        }
        guard let address = fields["server"], let server = Self.relay(address) else { return nil }
        self.init(sessionId: id, server: server)
    }

    public var webURL: URL {
        var parts = URLComponents(string: "https://happier.nomada.cloud/native/index.html")!
        parts.queryItems = [URLQueryItem(name: "session", value: sessionId), URLQueryItem(name: "server", value: server.absoluteString)]
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url!
    }

    public var nativeURL: URL {
        var parts = URLComponents()
        parts.scheme = "happier-native"
        parts.host = "session"
        parts.path = "/" + sessionId
        parts.queryItems = [URLQueryItem(name: "server", value: server.absoluteString)]
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url!
    }

    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id != "." && id != ".." && !id.contains("/") && !id.contains("\\") && !id.contains("?") && !id.contains("#") && !id.contains("%")
            && id.unicodeScalars.allSatisfy { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }
    }

    private static func relay(_ value: String) -> URL? {
        guard value.contains("://"), !value.contains("\\"),
              value.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: value),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard scheme == "https" || (scheme == "http" && loopback) else { return nil }
        return ServerAddress.normalize(value)
    }
}

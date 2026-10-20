import Foundation

/// The relays (Happier servers) this device has signed in to, for switching between them.
public enum RelayList {
    /// Appends `url` unless the same relay is already listed (`https://host` and `https://host/`).
    public static func adding(_ url: URL, to list: [URL]) -> [URL] {
        let key = canonical(url)
        guard !list.contains(where: { canonical($0) == key }) else { return list }
        return list + [URL(string: key) ?? url]
    }

    public static func canonical(_ url: URL) -> String {
        var text = url.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// The short build id from `GET /v1/version` (`{ ok, source_sha }`).
    public static func build(fromVersion response: JSONValue) -> String? {
        response["source_sha"]?.stringValue.map { String($0.prefix(7)) }
    }
}

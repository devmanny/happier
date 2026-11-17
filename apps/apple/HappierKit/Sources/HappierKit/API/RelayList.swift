import Foundation

/// The relays (Happier servers) this device has signed in to, for switching between them.
public enum RelayList {
    /// Appends `url` unless the same relay is already listed (see `canonical`), as it is spelled
    /// (without trailing slashes): its sign-in is kept in the Keychain under that spelling.
    public static func adding(_ url: URL, to list: [URL]) -> [URL] {
        let key = canonical(url)
        guard !list.contains(where: { canonical($0) == key }) else { return list }
        return list + [URL(string: trimmingSlashes(url.absoluteString)) ?? url]
    }

    /// Which relay `url` is: scheme and host in lower case, without the scheme's default port or
    /// trailing slashes, as `new URL(…).toString()` writes it (what the CLI and the web app send).
    /// The path stays as is. Compare relays with this; never use it as a Keychain name.
    public static func canonical(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = parts.scheme?.lowercased() else {
            return trimmingSlashes(url.absoluteString)
        }
        parts.scheme = scheme
        if let host = parts.percentEncodedHost { parts.percentEncodedHost = host.lowercased() }
        if parts.port == (scheme == "https" ? 443 : scheme == "http" ? 80 : nil) { parts.port = nil }
        return trimmingSlashes(parts.string ?? url.absoluteString)
    }

    private static func trimmingSlashes(_ text: String) -> String {
        var text = text
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// The short build id from `GET /v1/version` (`{ ok, source_sha }`).
    public static func build(fromVersion response: JSONValue) -> String? {
        response["source_sha"]?.stringValue.map { String($0.prefix(7)) }
    }
}

import Foundation

/// User-entered server addresses: bare hosts default to https, trailing slashes are dropped.
public enum ServerAddress {
    public static func normalize(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty
        else { return nil }
        return components.url
    }

    /// Whether `url` names this device, so no other device can reach it: `isLoopbackHostname`
    /// (`packages/protocol/src/serverUrls/loopbackHostname.ts`): `localhost` and all of
    /// `*.localhost`, `127.0.0.0/8` and `::1`, brackets and a trailing dot ignored. Reachability, not
    /// identity: which relay a URL is stays `RelayList.canonical`.
    public static func isLoopback(_ url: URL) -> Bool {
        guard let raw = url.host(percentEncoded: false) else { return false }
        var host = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts.allSatisfy({ (1...3).contains($0.count) && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return false }
        let octets = parts.compactMap { Int($0) }
        return octets.count == 4 && octets.allSatisfy { $0 <= 255 } && octets[0] == 127
    }
}

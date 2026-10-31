import Foundation

/// A Markdown link to a file on the session's computer, resolved by its existing transfer route.
public struct RemoteFileLink: Equatable, Sendable {
    public let path: String
    public let name: String

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        var path = components.path // URLComponents decodes once; query and fragment are separate.
        if let scheme = components.scheme {
            if scheme.lowercased() == "file" {
                guard components.user == nil, components.password == nil, components.port == nil,
                      components.host == nil || components.host == "" || components.host?.lowercased() == "localhost" else { return nil }
                // A drive file URI spells C:/... as file:///C:/... . Keep the machine's drive path.
                if path.hasPrefix("/"), Self.isWindowsDrivePath(String(path.dropFirst())) { path.removeFirst() }
            } else {
                // Foundation sees C:/... and C:\... as a one-letter URL scheme.
                // An authority makes this a remote/custom URL, never a drive path.
                guard components.host == nil, components.user == nil, components.password == nil, components.port == nil else { return nil }
                path = scheme + ":" + path
                guard Self.isWindowsDrivePath(path) else { return nil }
            }
        } else {
            guard components.host == nil, components.user == nil, components.password == nil, components.port == nil else { return nil }
        }
        guard !path.isEmpty, !path.contains("\0"), !path.hasSuffix("/"), !path.hasSuffix("\\"),
              let name = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init),
              name != ".", name != ".." else { return nil }
        self.path = path
        self.name = name
    }

    static func isAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/") || isWindowsDrivePath(path)
    }

    private static func isWindowsDrivePath(_ path: String) -> Bool {
        path.range(of: #"\A[A-Za-z]:[/\\]"#, options: .regularExpression) != nil
    }
}

/// Where a link tapped in a conversation goes: a file on the session's computer opens its
/// preview; a web page asks whether to open in Happier's browser or the default one; anything
/// else (mail, phone, app links) goes to the system.
public enum ConversationLink: Equatable, Sendable {
    case file(RemoteFileLink)
    case webPage(URL)
    case other(URL)

    public init(_ url: URL) {
        if let file = RemoteFileLink(url: url) {
            self = .file(file)
        } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            self = .webPage(url)
        } else {
            self = .other(url)
        }
    }
}

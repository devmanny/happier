import Foundation

/// Routes OS-delivered links without treating an ordinary website as a session link.
public enum AppLink: Equatable, Sendable {
    case inbox, newSession, share, session, website

    public init?(url: URL, isBrowserRole: Bool = false) {
        switch (url.scheme?.lowercased(), url.host?.lowercased()) {
        case ("happier-native", "inbox"): self = .inbox
        case ("happier-native", "new"): self = .newSession
        case ("happier-native", "share"): self = .share
        case ("happier-native", _): self = .session // The store owns validation and errors.
        case ("http", _), ("https", _):
            guard let host = url.host, !host.isEmpty else { return nil }
            // A default browser renders the requested page, including our session landing page.
            self = !isBrowserRole && SessionLink(url: url) != nil ? .session : .website
        default: return nil
        }
    }
}

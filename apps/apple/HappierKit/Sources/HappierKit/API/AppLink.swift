import Foundation

/// Routes OS-delivered links without treating an ordinary website as a session link.
public enum AppLink: Equatable, Sendable {
    case inbox, newSession, share, session, website, tasks
    case browserImport(UUID)
    /// One task's detail (`happier-native://task/<id>`), as the My Tasks widget links it.
    case task(String)

    public init?(url: URL, isBrowserRole: Bool = false) {
        switch (url.scheme?.lowercased(), url.host?.lowercased()) {
        case ("happier-native", "inbox"): self = .inbox
        case ("happier-native", "new"): self = .newSession
        case ("happier-native", "share"): self = .share
        case ("happier-native", "tasks"): self = .tasks
        case ("happier-native", "task"):
            let id = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            self = url.pathComponents.count == 2 && !id.isEmpty && id != "/" ? .task(id) : .tasks
        case ("happier-native", "browser-import"):
            guard url.user == nil, url.password == nil, url.port == nil,
                  url.query == nil, url.fragment == nil,
                  url.pathComponents.count == 2, let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            self = .browserImport(id)
        case ("happier-native", _): self = .session // The store owns validation and errors.
        case ("http", _), ("https", _):
            guard let host = url.host, !host.isEmpty else { return nil }
            // A default browser renders the requested page, including our session landing page.
            self = !isBrowserRole && SessionLink(url: url) != nil ? .session : .website
        default: return nil
        }
    }
}

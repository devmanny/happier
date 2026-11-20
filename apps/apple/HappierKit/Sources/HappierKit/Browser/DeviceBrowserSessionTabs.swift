import Foundation

/// One browser call and the session it acts for (`sessionId`, set by the CLI from the calling
/// session's MCP bridge, never by the agent).
public struct DeviceBrowserCommand: Equatable, Sendable {
    public let sessionId: String
    public let request: DeviceBrowserRequest

    public init(sessionId: String, request: DeviceBrowserRequest) {
        self.sessionId = sessionId
        self.request = request
    }

    public init(json: JSONValue) throws(DeviceBrowserError) {
        let sessionId = json["sessionId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !sessionId.isEmpty else {
            throw DeviceBrowserError(.invalidRequest, "sessionId is required; update the Happier CLI on the session's machine")
        }
        self.init(sessionId: sessionId, request: try DeviceBrowserRequest(json: json))
    }
}

public enum DeviceBrowserTabOwner: Hashable, Sendable {
    /// Opened by the person using the app; no agent touches it.
    case user
    case session(String)
}

/// Which tab belongs to whom, and each session's current tab (where calls without `tabId` go).
/// A session reaches only its own tabs; any other id answers `tab_not_found`, so other sessions'
/// and the user's tabs stay invisible.
public struct DeviceBrowserTabRegistry: Sendable {
    public struct Resolved: Equatable, Sendable {
        public let id: String
        public let created: Bool
        public init(id: String, created: Bool) {
            self.id = id
            self.created = created
        }
    }

    private var owners: [String: DeviceBrowserTabOwner] = [:]
    private var order: [String] = []
    private var current: [String: String] = [:]
    private var nextNumber = 1

    public init() {}

    public var allTabs: [String] { order }

    public func owner(of tabId: String) -> DeviceBrowserTabOwner? { owners[tabId] }

    public func tabs(of sessionId: String) -> [String] { order.filter { owners[$0] == .session(sessionId) } }

    public func currentTab(of sessionId: String) -> String? { current[sessionId] }

    /// A new tab; for a session it becomes that session's current tab.
    public mutating func open(for owner: DeviceBrowserTabOwner) -> String {
        let id = "t\(nextNumber)"
        nextNumber += 1
        owners[id] = owner
        order.append(id)
        if case .session(let sessionId) = owner { current[sessionId] = id }
        return id
    }

    /// The tab a call acts on: the given one if the session owns it, else the session's current
    /// tab, created on first use when `create` allows.
    public mutating func tab(for sessionId: String, tabId: String?, create: Bool) throws(DeviceBrowserError) -> Resolved {
        if let tabId {
            try requireOwned(tabId, by: sessionId)
            return .init(id: tabId, created: false)
        }
        if let id = current[sessionId] { return .init(id: id, created: false) }
        guard create else { throw DeviceBrowserError(.tabNotFound, "This session has no tab yet; navigate to a URL first") }
        return .init(id: open(for: .session(sessionId)), created: true)
    }

    public mutating func select(_ tabId: String, for sessionId: String) throws(DeviceBrowserError) {
        try requireOwned(tabId, by: sessionId)
        current[sessionId] = tabId
    }

    public mutating func close(_ tabId: String, for sessionId: String) throws(DeviceBrowserError) {
        try requireOwned(tabId, by: sessionId)
        close(tabId)
    }

    /// Forgets a tab; its session's current tab moves to its most recent remaining one.
    public mutating func close(_ tabId: String) {
        guard let owner = owners.removeValue(forKey: tabId) else { return }
        order.removeAll { $0 == tabId }
        if case .session(let sessionId) = owner, current[sessionId] == tabId {
            current[sessionId] = tabs(of: sessionId).last
        }
    }

    /// Session tabs to close: their session is no longer live, and the user is not looking at them.
    public func tabsToClose(liveSessionIds: Set<String>, visibleTabIds: Set<String>) -> [String] {
        order.filter { id in
            guard case .session(let sessionId) = owners[id] else { return false }
            return !liveSessionIds.contains(sessionId) && !visibleTabIds.contains(id)
        }
    }

    private func requireOwned(_ tabId: String, by sessionId: String) throws(DeviceBrowserError) {
        guard owners[tabId] == .session(sessionId) else { throw DeviceBrowserError(.tabNotFound, "No tab \(tabId)") }
    }
}

/// Runs operations one at a time per key (a tab) while different keys run alongside each other.
@MainActor public final class KeyedSerialQueue {
    private var tails: [String: Task<Void, Never>] = [:]

    public init() {}

    public func run<T: Sendable>(_ key: String, _ operation: @escaping @MainActor () async -> T) async -> T {
        let previous = tails[key]
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        let tail = Task { @MainActor in _ = await task.value }
        tails[key] = tail
        let result = await task.value
        // The last caller of a key clears it, so idle tabs leave nothing behind.
        if tails[key] == tail { tails[key] = nil }
        return result
    }
}

/// Tells when a session that owns browser tabs has ended: archived, stopped after being seen
/// running, or gone from the list after being seen. A session not known yet, or first seen idle
/// (its list entry can lag behind the running agent), keeps its tabs.
public struct DeviceBrowserSessionWatch: Sendable {
    public struct State: Equatable, Sendable {
        public let active: Bool
        public let archived: Bool
        public init(active: Bool, archived: Bool) {
            self.active = active
            self.archived = archived
        }
    }

    private var seen: [String: Bool] = [:]

    public init() {}

    /// Records the session's latest state; true once it has ended.
    public mutating func observe(_ sessionId: String, _ state: State?) -> Bool {
        let previous = seen[sessionId]
        guard let state else { return previous != nil }
        seen[sessionId] = state.active
        if state.archived { return true }
        return previous == true && !state.active
    }
}

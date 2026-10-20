import Foundation

/// Typed wrappers over the Happier HTTP routes used by the native client (`docs/api.md`).
public struct HappierAPI: Sendable {
    public struct MessagePage: Sendable {
        public let rows: [JSONValue]
        public let hasMore: Bool
        public let nextBeforeSeq: Int?
        public let nextAfterSeq: Int?
    }

    let http: HTTPClient

    public init(server: URL, token: String, session: URLSession = .shared) {
        http = HTTPClient(baseURL: server, token: token, session: session)
    }

    /// All non-archived sessions via `/v2/sessions` cursor paging; falls back to `/v1/sessions`.
    public func listSessions() async throws -> [JSONValue] {
        var rows: [JSONValue] = []
        var cursor: String?
        do {
            repeat {
                var query = ["limit": "200"]
                if let cursor { query["cursor"] = cursor } else {
                    query["includeActive"] = "true"
                    query["includeAttention"] = "true"
                }
                let page = try await http.get("/v2/sessions", query: query)
                rows += page["sessions"]?.arrayValue ?? []
                cursor = page["hasNext"]?.boolValue == true ? page["nextCursor"]?.stringValue : nil
            } while cursor != nil
        } catch let error as HTTPClient.ServerError where [404, 405, 501].contains(error.status) {
            return try await http.get("/v1/sessions")["sessions"]?.arrayValue ?? []
        }
        // `includeActive` can merge rows that later pages also contain.
        var seen = Set<String>()
        return rows.filter { seen.insert($0["id"]?.stringValue ?? "").inserted }
    }

    public func session(id: String) async throws -> JSONValue? {
        try await http.get("/v2/sessions/\(id)")["session"]
    }

    /// Without `afterSeq` rows are newest-first; with `afterSeq` oldest-first.
    public func messages(sessionId: String, beforeSeq: Int? = nil, afterSeq: Int? = nil, limit: Int = 50) async throws -> MessagePage {
        var query = ["scope": "main", "limit": String(limit)]
        if let beforeSeq { query["beforeSeq"] = String(beforeSeq) }
        if let afterSeq { query["afterSeq"] = String(afterSeq) }
        let page = try await http.get("/v1/sessions/\(sessionId)/messages", query: query)
        return MessagePage(
            rows: page["messages"]?.arrayValue ?? [], hasMore: page["hasMore"]?.boolValue ?? false,
            nextBeforeSeq: page["nextBeforeSeq"]?.intValue, nextAfterSeq: page["nextAfterSeq"]?.intValue)
    }

    /// Pending Queue V2 (`pendingQueueV2.ts`): the CLI commits the row into the transcript with the same `localId`.
    public func enqueueUserMessage(sessionId: String, localId: String, content: JSONValue, action: PendingAction = .enqueue) async throws {
        var body: [String: JSONValue] = [
            "localId": .string(localId), "messageRole": "user", "requestedAction": ["v": 1, "kind": .string(action.rawValue)],
        ]
        if case .string(let ciphertext) = content { body["ciphertext"] = .string(ciphertext) } else { body["content"] = content }
        _ = try await http.post("/v2/sessions/\(sessionId)/pending", .object(body))
    }

    public func machines() async throws -> [JSONValue] {
        try await http.get("/v1/machines").arrayValue ?? []
    }

    public func machine(id: String) async throws -> JSONValue? {
        try await http.get("/v1/machines/\(id)")["machine"]
    }

    // MARK: Pending queue (`pendingRoutes.ts`)

    public func pending(sessionId: String) async throws -> [JSONValue] {
        try await http.get("/v2/sessions/\(sessionId)/pending", query: ["includeDiscarded": "1"])["pending"]?.arrayValue ?? []
    }

    public func editPending(sessionId: String, localId: String, content: JSONValue) async throws {
        var body: [String: JSONValue] = ["messageRole": "user"]
        if case .string(let ciphertext) = content { body["ciphertext"] = .string(ciphertext) } else { body["content"] = content }
        _ = try await http.patch("/v2/sessions/\(sessionId)/pending/\(localId)", .object(body))
    }

    public func setPendingAction(sessionId: String, localId: String, action: PendingAction) async throws {
        _ = try await http.patch("/v2/sessions/\(sessionId)/pending/\(localId)/action",
                                 ["requestedAction": ["v": 1, "kind": .string(action.rawValue)]])
    }

    public func removePending(sessionId: String, localId: String) async throws {
        _ = try await http.delete("/v2/sessions/\(sessionId)/pending/\(localId)")
    }

    public func restorePending(sessionId: String, localId: String) async throws {
        _ = try await http.post("/v2/sessions/\(sessionId)/pending/\(localId)/restore")
    }

    public func markRead(sessionId: String) async throws {
        _ = try await http.post("/v2/sessions/\(sessionId)/read-state", ["state": "read"])
    }

    public func archive(sessionId: String) async throws {
        _ = try await http.post("/v2/sessions/\(sessionId)/archive")
    }

    public func delete(sessionId: String) async throws {
        _ = try await http.delete("/v1/sessions/\(sessionId)")
    }

    // MARK: Session organization (`sessionOrganizationApi.ts`)

    /// Pins only: folders, tags and labels are left out of the snapshot.
    public func sessionOrganizationPins() async throws -> JSONValue {
        try await http.get("/v2/session-organization",
                           query: ["includeFolders": "false", "includeTags": "false", "includeLabels": "false"])
    }

    public func setSessionPin(_ sessionId: String, pinned: Bool) async throws {
        _ = try await http.put("/v2/session-organization/pins/\(sessionId)", ["pinned": .bool(pinned)])
    }

    // MARK: Push (`pushRoutes.ts`)

    /// `clientServerUrl` tells the CLI which server a tapped notification belongs to.
    public func registerPushToken(_ token: String, clientServerUrl: URL) async throws {
        _ = try await http.post("/v1/push-tokens", ["token": .string(token), "clientServerUrl": .string(clientServerUrl.absoluteString)])
    }

    public func deletePushToken(_ token: String) async throws {
        // `appending(path:)` percent-encodes whatever the token needs (`ExponentPushToken[…]`, `apns:…`).
        _ = try await http.delete("/v1/push-tokens/\(token)")
    }
}

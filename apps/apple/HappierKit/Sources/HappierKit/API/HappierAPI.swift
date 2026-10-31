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

    // MARK: Linking another device (the signed-in side)

    /// Whether the Account keeps content end-to-end encrypted (`GET /v1/account/encryption`); a relay
    /// without the route is treated as encrypted, as the TypeScript client does.
    public func accountIsEncrypted() async throws -> Bool {
        do {
            return try await http.get("/v1/account/encryption")["mode"]?.stringValue != "plain"
        } catch let error as HTTPClient.ServerError where error.status == 404 {
            return true
        }
    }

    /// The Account's published keys (`GET /v1/user/:id`), nil when the relay doesn't know it.
    public func accountLinkProfile(accountId: String) async throws -> AccountLinkProfile? {
        let user: JSONValue?
        do {
            user = try await http.get("/v1/user/\(accountId)")["user"]
        } catch let error as HTTPClient.ServerError where error.status == 404 {
            return nil
        }
        guard let user, user["id"]?.stringValue == accountId else { return nil }
        return AccountLinkProfile(publicKey: user["publicKey"]?.stringValue,
                                  contentPublicKey: user["contentPublicKey"]?.stringValue,
                                  contentPublicKeySig: user["contentPublicKeySig"]?.stringValue)
    }

    /// Hands the sealed credentials to the waiting device (`POST /v1/auth/account/response`).
    public func approveAccountLink(publicKey: Data, response: Data) async throws {
        _ = try await http.post("/v1/auth/account/response", [
            "publicKey": .string(publicKey.base64EncodedString()),
            "response": .string(response.base64EncodedString()),
        ])
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

    /// The account's change cursor (`/v2/cursor`); a snapshot taken after reading it is current
    /// up to it.
    public func changesCursor() async throws -> Int? {
        try await http.get("/v2/cursor")["cursor"]?.intValue
    }

    /// Entities changed after `cursor` (`/v2/changes`); nil when the cursor is gone (410) and only
    /// a fresh snapshot can catch up.
    public func changes(after cursor: Int, limit: Int) async throws -> JSONValue? {
        do {
            return try await http.get("/v2/changes", query: ["after": String(cursor), "limit": String(limit)])
        } catch let error as HTTPClient.ServerError where error.status == 410 {
            return nil
        }
    }

    /// Without `afterSeq` rows are newest-first; with `afterSeq` oldest-first.
    /// `limit` defaults to the server's own page size.
    /// The conversation's own messages, or one subagent's thread (`sidechainId`, the id of the tool
    /// call that started it).
    public func messages(sessionId: String, beforeSeq: Int? = nil, afterSeq: Int? = nil, limit: Int? = nil,
                         sidechainId: String? = nil) async throws -> MessagePage {
        var query = ["scope": sidechainId == nil ? "main" : "sidechain"]
        if let sidechainId { query["sidechainId"] = sidechainId }
        if let limit { query["limit"] = String(limit) }
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

    /// Removes a machine from the account (`POST /v1/machines/:id/revoke`): its access keys and
    /// automation assignments go; it can sign in again from the CLI.
    public func revokeMachine(id: String) async throws {
        _ = try await http.post("/v1/machines/\(id)/revoke")
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

    public func setReadState(sessionId: String, read: Bool) async throws {
        _ = try await http.post("/v2/sessions/\(sessionId)/read-state", ["state": .string(read ? "read" : "unread")])
    }

    public func archive(sessionId: String) async throws {
        _ = try await http.post("/v2/sessions/\(sessionId)/archive")
    }

    public func unarchive(sessionId: String) async throws {
        _ = try await http.post("/v2/sessions/\(sessionId)/unarchive")
    }

    /// A provider-usage snapshot (`providerAccountUsageRoutesV2/V3.ts`): sealed for the account on
    /// end-to-end encrypted accounts (`/v2`, opened with the account's content key), else plain (`/v3`).
    public func providerAccountUsage(recordId: String, machineKey: Data?) async throws -> JSONValue? {
        if let machineKey {
            do {
                let sealed = try await http.get("/v2/connect/provider-account-usage/\(recordId)")
                if let ciphertext = sealed["sealed"]?["ciphertext"]?.stringValue {
                    return AccountScopedBlob.open(ciphertext, kind: .providerAccountUsageSnapshot, machineKey: machineKey)
                }
            } catch let error as HTTPClient.ServerError where error.status == 404 {}
        }
        let response = try await http.get("/v3/connect/provider-account-usage/\(recordId)")
        return response["content"]?["t"]?.stringValue == "plain" ? response["content"]?["v"] : nil
    }

    /// A session's synced composer draft (`registerSessionDraftRoutes.ts`): nil when there is none.
    public func readSessionDraft(sessionId: String) async throws -> SessionDraft.Record? {
        SessionDraft.Record(response: try await http.post("/v1/account/session-drafts/read", ["address": SessionDraft.address(sessionId)]))
    }

    /// Writes the draft over `expectedRevision` (nil: there was none); nil content clears it.
    public func mutateSessionDraft(sessionId: String, expectedRevision: Int?, content: JSONValue?) async throws -> SessionDraft.Outcome? {
        SessionDraft.Outcome(response: try await http.post("/v1/account/session-drafts/mutate", [
            "address": SessionDraft.address(sessionId),
            "expectedRevision": expectedRevision.map { .number(Double($0)) } ?? "absent",
            "content": content ?? .null,
        ]))
    }

    /// A session's system records of one kind, every page (`registerSessionSystemRecordRoutes.ts`).
    public func systemRecords(sessionId: String, namespace: String, kind: String) async throws -> [JSONValue] {
        var records: [JSONValue] = []
        var cursor: String?
        repeat {
            var query = ["namespace": namespace, "kind": kind, "limit": "100"]
            if let cursor { query["cursor"] = cursor }
            let page = try await http.get("/v2/sessions/\(sessionId)/system-records", query: query)
            records += page["records"]?.arrayValue ?? []
            cursor = page["hasNext"]?.boolValue == true ? page["nextCursor"]?.stringValue : nil
        } while cursor != nil
        return records
    }

    /// One page of archived sessions, most recent activity first (`/v2/sessions/archived`).
    public func archivedSessions(cursor: String?, limit: Int) async throws -> (rows: [JSONValue], nextCursor: String?) {
        var query = ["limit": String(limit)]
        if let cursor { query["cursor"] = cursor }
        let page = try await http.get("/v2/sessions/archived", query: query)
        let next = page["hasNext"]?.boolValue == true ? page["nextCursor"]?.stringValue : nil
        return (page["sessions"]?.arrayValue ?? [], next)
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

    // MARK: Account settings (`registerAccountSettingsRoutes.ts`)

    public enum AccountSettingsWrite: Sendable {
        case saved(version: Int)
        /// Someone else wrote first: their document and version, to merge onto and retry.
        case conflict(version: Int, content: JSONValue?)
    }

    /// The stored document (`{t:'encrypted', c}`, `{t:'plain', v}` or nil) and its version;
    /// `/v1` on relays without `/v2` (encrypted accounts only there).
    public func accountSettings() async throws -> (content: JSONValue?, version: Int) {
        do {
            let response = try await http.get("/v2/account/settings")
            return (response["content"].flatMap { $0.isNull ? nil : $0 }, response["version"]?.intValue ?? 0)
        } catch let error as HTTPClient.ServerError where error.status == 404 {
            let response = try await http.get("/v1/account/settings")
            return (response["settings"]?.stringValue.map { ["t": "encrypted", "c": .string($0)] }, response["settingsVersion"]?.intValue ?? 0)
        }
    }

    public func writeAccountSettings(_ content: JSONValue, expectedVersion: Int) async throws -> AccountSettingsWrite {
        let response: JSONValue
        let legacy: Bool
        do {
            response = try await http.post("/v2/account/settings", ["content": content, "expectedVersion": .number(Double(expectedVersion))])
            legacy = false
        } catch let error as HTTPClient.ServerError where error.status == 404 {
            guard content["t"]?.stringValue == "encrypted", let ciphertext = content["c"] else { throw error }
            response = try await http.post("/v1/account/settings", ["settings": ciphertext, "expectedVersion": .number(Double(expectedVersion))])
            legacy = true
        }
        if response["success"]?.boolValue == true {
            return .saved(version: response["version"]?.intValue ?? expectedVersion + 1)
        }
        guard response["error"]?.stringValue == "version-mismatch", let current = response["currentVersion"]?.intValue else {
            throw HTTPClient.ServerError(status: 200, path: "/v2/account/settings", body: response)
        }
        let content = legacy
            ? response["currentSettings"]?.stringValue.map { ["t": "encrypted", "c": .string($0)] }
            : response["currentContent"].flatMap { $0.isNull ? nil : $0 }
        return .conflict(version: current, content: content)
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

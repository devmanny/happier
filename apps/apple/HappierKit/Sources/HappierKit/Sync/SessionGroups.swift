import Foundation

/// A group of sessions the user made: one of the account's session organization folders
/// (`/v2/session-organization`, feature `sessions.folders`); a session is in one group at most. The
/// web app nests its folders under a project and lists only those, so the groups made here (which
/// hold sessions of any folder) aren't listed there, and it leaves them as they are.
public struct SessionGroup: Identifiable, Equatable, Sendable {
    public let id: String
    /// As listed: a group inside another (made in the web app) reads "Kelpi › Diseño".
    public let name: String
    /// Its own name, without the groups it's inside.
    public let ownName: String
    let folderKey: String
    let parentId: String?
    let parentKey: String?
    let sortKey: String?
    /// The display payload as stored (`{name, workspace}` from the web app), kept whole so a rename
    /// changes only the name.
    let payload: [String: JSONValue]

    init(id: String, name: String, folderKey: String? = nil, parentId: String? = nil, parentKey: String? = nil, sortKey: String? = nil,
         payload: [String: JSONValue]? = nil) {
        self.id = id
        self.name = name
        ownName = name
        self.folderKey = folderKey ?? id
        self.parentId = parentId
        self.parentKey = parentKey
        self.sortKey = sortKey
        self.payload = payload ?? ["name": .string(name)]
    }

    private init(_ group: SessionGroup, listedAs name: String) {
        id = group.id
        self.name = name
        ownName = group.ownName
        folderKey = group.folderKey
        parentId = group.parentId
        parentKey = group.parentKey
        sortKey = group.sortKey
        payload = group.payload
    }

    /// The web app's limit (`folders/constants.ts`).
    public static let maximumNameLength = 80

    /// The name as saved: trimmed and at most `maximumNameLength`; nil when nothing is left.
    public static func cleanName(_ name: String) -> String? {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumNameLength))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A new group: ids as the web app makes them (`sessionOrganizationIdAllocation.ts`), the key the id.
    static func new(named name: String) -> SessionGroup {
        SessionGroup(id: "folder_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), name: name)
    }

    /// The same group under another name, the rest of what it stores kept.
    func renamed(_ name: String) -> SessionGroup {
        var payload = payload
        payload["name"] = .string(name)
        return SessionGroup(id: id, name: name, folderKey: folderKey, parentId: parentId, parentKey: parentKey, sortKey: sortKey, payload: payload)
    }

    /// `POST /v2/session-organization/folders`: every field, since the relay overwrites them all.
    func request(display: JSONValue) -> JSONValue {
        ["folderId": .string(id), "folderKey": .string(folderKey), "parentFolderId": parentId.map(JSONValue.string) ?? .null,
         "parentFolderKey": parentKey.map(JSONValue.string) ?? .null, "sortKey": sortKey.map(JSONValue.string) ?? .null, "display": display]
    }

    /// The name sealed for the account's devices (`session_organization_display`), or plain on a
    /// plain account, which is the only one the relay takes plain names from.
    func display(machineKey: Data?, plain: Bool) throws -> JSONValue {
        if plain { return ["t": "plain", "v": .object(payload)] }
        guard let machineKey else { throw HappierCrypto.Failure.invalidLength }
        return ["t": "encrypted", "c": .string(try AccountScopedBlob.seal(.object(payload), kind: .sessionOrganizationDisplay, machineKey: machineKey))]
    }

    /// The group whose section lists a session's row: its own group, or else the one of the session
    /// it's listed under (`parent`), up the family; none for a pinned one, listed in Pinned.
    static func listedGroupId(of sessionId: String, groupIds: [String: String], pinned: Set<String>,
                              parent: (String) -> String?) -> String? {
        var current = sessionId
        var seen: Set<String> = []
        while seen.insert(current).inserted {
            if pinned.contains(current) { return nil }
            if let group = groupIds[current] { return group }
            guard let next = parent(current) else { return nil }
            current = next
        }
        return nil
    }

    /// Groups in list order: each followed by the ones inside it, siblings by their sort key, then
    /// name, then id (`tree.ts`); inner ones are listed with the names of the ones they're in.
    static func ordered(_ groups: [SessionGroup]) -> [SessionGroup] {
        let ids = Set(groups.map(\.id))
        let children = Dictionary(grouping: groups) { group in group.parentId.flatMap { ids.contains($0) ? $0 : nil } ?? "" }
        func sorted(_ siblings: [SessionGroup]) -> [SessionGroup] {
            siblings.sorted { a, b in
                switch (a.sortKey, b.sortKey) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default:
                    let (x, y) = (a.ownName.lowercased(), b.ownName.lowercased())
                    return x != y ? x < y : a.id < b.id
                }
            }
        }
        var listed: [SessionGroup] = []
        var seen: Set<String> = []
        func walk(_ parent: String, prefix: String?) {
            for group in sorted(children[parent] ?? []) where seen.insert(group.id).inserted {
                let name = prefix.map { "\($0) › \(group.ownName)" } ?? group.ownName
                listed.append(SessionGroup(group, listedAs: name))
                walk(group.id, prefix: name)
            }
        }
        walk("", prefix: nil)
        return listed
    }
}

/// What the account's session organization says about the list: the pinned sessions and the groups.
public struct SessionOrganization: Equatable, Sendable {
    public var pinnedIds: [String]
    /// In list order (`SessionGroup.ordered`).
    public var groups: [SessionGroup]
    /// Each grouped session's group, for the groups in `groups` only.
    public var groupIds: [String: String]

    /// From `GET /v2/session-organization`; a folder whose name this device can't read isn't a group.
    init(snapshot response: JSONValue, machineKey: Data?) {
        let snapshot = response["snapshot"]
        pinnedIds = SessionPins.orderedIds(fromSnapshot: response)
        let groups = (snapshot?["folders"]?.arrayValue ?? []).compactMap { folder -> SessionGroup? in
            guard let id = folder["folderId"]?.stringValue, folder["archivedAt"]?.isNull != false,
                  let payload = Self.payload(folder["display"], machineKey: machineKey),
                  let name = payload["name"]?.stringValue.flatMap(SessionGroup.cleanName) else { return nil }
            return SessionGroup(id: id, name: name, folderKey: folder["folderKey"]?.stringValue, parentId: folder["parentFolderId"]?.stringValue,
                                parentKey: folder["parentFolderKey"]?.stringValue, sortKey: folder["sortKey"]?.stringValue, payload: payload)
        }
        self.groups = SessionGroup.ordered(groups)
        let known = Set(groups.map(\.id))
        var groupIds: [String: String] = [:]
        for assignment in snapshot?["folderAssignments"]?.arrayValue ?? [] {
            guard let sessionId = assignment["sessionId"]?.stringValue, let groupId = assignment["folderId"]?.stringValue,
                  known.contains(groupId) else { continue }
            groupIds[sessionId] = groupId
        }
        self.groupIds = groupIds
    }

    /// A folder's display payload: `{t:'plain', v}`, or `{t:'encrypted', c}` sealed for the account
    /// (headed, or the older headerless format, as `openAccountScopedBlobCiphertext` reads it).
    private static func payload(_ display: JSONValue?, machineKey: Data?) -> [String: JSONValue]? {
        switch display?["t"]?.stringValue {
        case "plain":
            return display?["v"]?.objectValue
        case "encrypted":
            guard let machineKey, let ciphertext = display?["c"]?.stringValue else { return nil }
            return (AccountScopedBlob.open(ciphertext, kind: .sessionOrganizationDisplay, machineKey: machineKey)
                ?? AccountScopedBlob.openHeaderless(ciphertext, keys: [machineKey]))?.objectValue
        default:
            return nil
        }
    }

    /// Whether the relay keeps groups: `features.sessions.folders` on (and sessions), from
    /// `GET /v1/features`; anything missing is off (`readServerEnabledBit`).
    static func groupsEnabled(features response: JSONValue) -> Bool {
        let sessions = response["features"]?["sessions"]
        return sessions?["enabled"]?.boolValue == true && sessions?["folders"]?["enabled"]?.boolValue == true
    }
}

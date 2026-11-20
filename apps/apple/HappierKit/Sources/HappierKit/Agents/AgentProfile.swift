import Foundation

/// A user-defined agent (`packages/protocol/src/agentProfiles/agentIdentity.ts`): who it is, the
/// engine it runs on and the account it is tied to. Stored sealed for the account's devices in
/// the UserKVStore under the opaque key `agent/<id>/profile`; synced between iPhone, iPad and Mac.
public struct AgentProfile: Identifiable, Sendable, Equatable {
    public struct Account: Sendable, Equatable {
        /// What the user calls the account, e.g. "Claude DevManny".
        public var label: String
        /// Claude only: the agent's own Claude Code folder (`CLAUDE_CONFIG_DIR`), signed in once
        /// per machine with `claude login`. Nil uses the machine's own login.
        public var configDir: String?

        public init(label: String, configDir: String? = nil) {
            self.label = label
            self.configDir = configDir
        }
    }

    public let id: String
    public var name: String
    public var emoji: String?
    public var description: String?
    public var providerId: String
    public var modelId: String?
    public var effort: String?
    public var account: Account
    public var updatedAt: Double
    /// Keys other clients wrote that this one doesn't know; kept on rewrite.
    var extra: [String: JSONValue] = [:]

    public init(id: String = UUID().uuidString.lowercased(), name: String, emoji: String? = nil, description: String? = nil,
                providerId: String, modelId: String? = nil, effort: String? = nil, account: Account, updatedAt: Double = ServerClock.nowMs()) {
        self.id = id.lowercased()
        self.name = name
        self.emoji = emoji
        self.description = description
        self.providerId = providerId
        self.modelId = modelId
        self.effort = effort
        self.account = account
        self.updatedAt = updatedAt
    }

    /// What the app shows: the name. The emoji is part of the identity the agent is told
    /// (`identityJSON`), never drawn in the UI.
    public var label: String { name }

    /// The sidebar's selection for this agent's profile, which opens like a session (sessions are
    /// selected by their own id, so this one can never name a session).
    public static func selection(id: String) -> String { selectionPrefix + id }

    /// The agent whose profile `selection` names; nil for a session or nothing.
    public static func id(inSelection selection: String?) -> String? {
        guard let selection, selection.hasPrefix(selectionPrefix) else { return nil }
        let id = String(selection.dropFirst(selectionPrefix.count))
        return id.isEmpty ? nil : id
    }

    private static let selectionPrefix = "happier.agent:"

    /// The Claude Code folder this agent signs in with, when it has its own.
    public var claudeConfigDir: String? {
        guard providerId == "claude", let dir = account.configDir?.trimmingCharacters(in: .whitespaces), !dir.isEmpty else { return nil }
        return dir
    }

    // MARK: Storage

    /// Profiles have their own prefix, so an agent's memory (`agent/<id>/…`) can't crowd them out
    /// of a listing (one `GET /v1/kv` returns at most `KVListing.maxRows`).
    public static let kvPrefix = "agentprofile/"

    public static func kvKey(id: String) -> String { "agentprofile/\(id.lowercased())" }

    /// Where builds before the move keep profiles. Read and written alongside the new key while such
    /// builds may still be in use; remove both once no build older than the move is installed.
    public static let legacyKvPrefix = "agent/"

    public static func legacyKvKey(id: String) -> String { "agent/\(id.lowercased())/profile" }

    /// The agent id an `agentprofile/<id>` (or legacy `agent/<id>/profile`) key belongs to; nil for any other key.
    public static func id(fromKey key: String) -> String? {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2, parts[0] == "agentprofile", !parts[1].isEmpty { return String(parts[1]) }
        guard parts.count == 3, parts[0] == "agent", parts[2] == "profile", !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    /// What a refresh shows and what it must copy to the new keys. A profile only an old build knows
    /// is copied as new (version -1); one an old build edited after the move (newer `updatedAt`) is
    /// copied over the new key's version. Each copy is a versioned write, so when two devices migrate
    /// at once one write lands and the other just re-reads; the legacy keys are never deleted here.
    struct Reconciliation {
        var profiles: [AgentProfile]
        var copies: [Record]
    }

    static func reconcile(current: [Record], legacy: [Record]) -> Reconciliation {
        var byId = Dictionary(current.map { ($0.profile.id, $0) }, uniquingKeysWith: { $1 })
        var copies: [Record] = []
        for old in legacy {
            if let now = byId[old.profile.id] {
                guard old.profile.updatedAt > now.profile.updatedAt else { continue }
                copies.append(Record(profile: old.profile, version: now.version))
                byId[old.profile.id] = Record(profile: old.profile, version: now.version)
            } else {
                copies.append(Record(profile: old.profile, version: -1))
                byId[old.profile.id] = Record(profile: old.profile, version: -1)
            }
        }
        return Reconciliation(profiles: byId.values.map(\.profile), copies: copies)
    }

    var json: JSONValue {
        var object = extra
        object["v"] = 1
        object["id"] = .string(id)
        object["name"] = .string(name)
        object["emoji"] = emoji.map(JSONValue.string)
        object["description"] = description.map(JSONValue.string)
        object["providerId"] = .string(providerId)
        object["modelId"] = modelId.map(JSONValue.string)
        object["effort"] = effort.map(JSONValue.string)
        var account: [String: JSONValue] = ["label": .string(self.account.label)]
        if let dir = self.account.configDir, !dir.isEmpty { account["configDir"] = .string(dir) }
        object["account"] = .object(account)
        object["updatedAt"] = .number(updatedAt)
        return .object(object.filter { !$0.value.isNull })
    }

    init?(json: JSONValue) {
        guard let object = json.objectValue, object["v"]?.intValue == 1,
              let id = object["id"]?.stringValue, !id.isEmpty,
              let name = object["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        func text(_ key: String) -> String? { object[key]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
        self.init(id: id, name: name, emoji: text("emoji"), description: text("description"), providerId: text("providerId") ?? "claude",
                  modelId: text("modelId"), effort: text("effort"),
                  account: Account(label: object["account"]?["label"]?.stringValue ?? "",
                                   configDir: object["account"]?["configDir"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }),
                  updatedAt: object["updatedAt"]?.doubleValue ?? 0)
        let known: Set<String> = ["v", "id", "name", "emoji", "description", "providerId", "modelId", "effort", "account", "updatedAt"]
        extra = object.filter { !known.contains($0.key) }
    }

    func sealed(machineKey: Data) throws -> String {
        try AccountScopedBlob.seal(json, kind: .agentProfile, machineKey: machineKey)
    }

    static func open(_ value: String, machineKey: Data) -> AgentProfile? {
        AccountScopedBlob.open(value, kind: .agentProfile, machineKey: machineKey).flatMap(AgentProfile.init(json:))
    }

    struct Record: Sendable, Equatable {
        var profile: AgentProfile
        var version: Int
    }

    /// Readable profiles from a `GET /v1/kv` profile listing (either prefix); deleted rows (empty value),
    /// other keys under the prefix and rows this device can't open are skipped.
    static func records(fromList response: JSONValue, machineKey: Data) -> [Record] {
        (response["items"]?.arrayValue ?? []).compactMap { item in
            guard let key = item["key"]?.stringValue, let id = id(fromKey: key),
                  let value = item["value"]?.stringValue, !value.isEmpty,
                  let profile = open(value, machineKey: machineKey), profile.id == id else { return nil }
            return Record(profile: profile, version: item["version"]?.intValue ?? 0)
        }
    }

    // MARK: Spawn

    /// `agentIdentityV1` for the spawn: who the session works as.
    public var identityJSON: JSONValue {
        var identity: [String: JSONValue] = ["v": 1, "id": .string(id), "name": .string(name)]
        if let emoji, !emoji.isEmpty { identity["emoji"] = .string(emoji) }
        if let description, !description.isEmpty { identity["description"] = .string(description) }
        return .object(identity)
    }
}

/// The agent a session runs as, from its metadata (`agentIdentityV1`, written by the CLI).
public struct AgentIdentity: Sendable, Equatable {
    public let id: String
    public let name: String
    public let emoji: String?

    public init(id: String, name: String, emoji: String? = nil) {
        self.id = id
        self.name = name
        self.emoji = emoji
    }

    init?(json: JSONValue?) {
        guard let json, json["v"]?.intValue == 1, let id = json["id"]?.stringValue,
              let name = json["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        self.init(id: id, name: name, emoji: json["emoji"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// What the app shows: the name (the emoji stays in the session's identity, unrendered).
    public var label: String { name }
}

extension Session {
    public var agentIdentity: AgentIdentity? { AgentIdentity(json: metadata["agentIdentityV1"]) }
}

// MARK: - UserKVStore (`apps/server/sources/app/api/routes/kv/kvRoutes.ts`)

extension HappierAPI {
    public enum KVWrite: Equatable, Sendable {
        case saved(version: Int)
        /// Someone else wrote the key first: its version and value (nil when deleted), to retry on.
        case conflict(version: Int, value: String?)
    }

    func kvList(prefix: String) async throws -> JSONValue {
        try await http.get("/v1/kv", query: ["prefix": prefix, "limit": String(KVListing.maxRows)])
    }

    /// One key, written only if it is still at `version` (-1 for a new key); nil deletes it.
    func kvWrite(key: String, value: String?, version: Int) async throws -> KVWrite {
        do {
            let response = try await http.post("/v1/kv", Self.kvWriteBody(key: key, value: value, version: version))
            let saved = response["results"]?.arrayValue?.first { $0["key"]?.stringValue == key }
            return .saved(version: saved?["version"]?.intValue ?? version + 1)
        } catch let error as HTTPClient.ServerError where error.status == 409 {
            guard let conflict = error.body?["errors"]?.arrayValue?.first(where: { $0["key"]?.stringValue == key }),
                  conflict["error"]?.stringValue == "version-mismatch" else { throw error }
            return .conflict(version: conflict["version"]?.intValue ?? -1, value: conflict["value"]?.stringValue)
        }
    }
}

extension HappierAPI {
    public enum KVMutate: Equatable, Sendable {
        /// Every key was written: their new versions.
        case saved([String: Int])
        /// Nothing was written (the mutation is atomic): the keys someone else wrote first, with their
        /// current version and value (nil when deleted or absent), to retry on.
        case conflict([String: KVConflict])
    }

    public struct KVConflict: Equatable, Sendable {
        public let version: Int
        public let value: String?
    }

    /// Several keys written together or not at all (`kvMutate`), each only if still at its version.
    func kvMutate(_ mutations: [(key: String, value: String?, version: Int)]) async throws -> KVMutate {
        let body: JSONValue = ["mutations": .array(mutations.map { mutation in
            ["key": .string(mutation.key), "value": mutation.value.map(JSONValue.string) ?? .null, "version": .number(Double(mutation.version))]
        })]
        do {
            let response = try await http.post("/v1/kv", body)
            var versions: [String: Int] = [:]
            for result in response["results"]?.arrayValue ?? [] {
                if let key = result["key"]?.stringValue, let version = result["version"]?.intValue { versions[key] = version }
            }
            return .saved(versions)
        } catch let error as HTTPClient.ServerError where error.status == 409 {
            var conflicts: [String: KVConflict] = [:]
            for entry in error.body?["errors"]?.arrayValue ?? [] where entry["error"]?.stringValue == "version-mismatch" {
                guard let key = entry["key"]?.stringValue else { continue }
                conflicts[key] = KVConflict(version: entry["version"]?.intValue ?? -1, value: entry["value"]?.stringValue)
            }
            guard !conflicts.isEmpty else { throw error }
            return .conflict(conflicts)
        }
    }

    /// The stored values of `keys` that exist (`POST /v1/kv/bulk`, at most 100 keys a call).
    func kvBulkGet(_ keys: [String]) async throws -> [(key: String, value: String, version: Int)] {
        var rows: [(key: String, value: String, version: Int)] = []
        for start in stride(from: 0, to: keys.count, by: 100) {
            let chunk = Array(keys[start..<min(start + 100, keys.count)])
            let response = try await http.post("/v1/kv/bulk", ["keys": .array(chunk.map(JSONValue.string))])
            for row in response["values"]?.arrayValue ?? [] {
                if let key = row["key"]?.stringValue, let value = row["value"]?.stringValue, !value.isEmpty,
                   let version = row["version"]?.intValue {
                    rows.append((key, value, version))
                }
            }
        }
        return rows
    }

    /// The `POST /v1/kv` body `kvWrite` sends, so a writer can tell its size before sending it.
    static func kvWriteBody(key: String, value: String?, version: Int) -> JSONValue {
        ["mutations": [["key": .string(key), "value": value.map(JSONValue.string) ?? .null, "version": .number(Double(version))]]]
    }
}

/// `GET /v1/kv` returns at most `maxRows` rows and has no cursor: a listing that comes back this full
/// may have left rows out, and the app says so instead of cutting silently.
public enum KVListing {
    public static let maxRows = 1000

    public static func isComplete(_ response: JSONValue) -> Bool {
        (response["items"]?.arrayValue?.count ?? 0) < maxRows
    }
}

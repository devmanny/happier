import Foundation

/// An agent's memory shared by all its threads (`packages/protocol/src/agentProfiles/agentMemory.ts`),
/// sealed in the account's UserKVStore with kind `agent_memory`. Keys stay opaque:
/// `agent/<id>/now/<sessionId>`, `agent/<id>/journal/<YYYY-MM-DD>/<entryId>`, `agent/<id>/note/<noteId>`.
public struct AgentMemory: Sendable, Equatable {
    /// What one thread of the agent is doing now. Only that thread writes it.
    public struct Now: Sendable, Equatable, Identifiable {
        public var sessionId: String
        public var text: String
        public var title: String?
        public var directory: String?
        public var host: String?
        public var updatedAt: Double
        public var id: String { sessionId }

        public init(sessionId: String, text: String, title: String? = nil, directory: String? = nil, host: String? = nil, updatedAt: Double) {
            self.sessionId = sessionId
            self.text = text
            self.title = title
            self.directory = directory
            self.host = host
            self.updatedAt = updatedAt
        }

        init?(json: JSONValue) {
            guard json["v"]?.intValue == 1, let sessionId = json["sessionId"]?.stringValue, !sessionId.isEmpty,
                  let text = json["text"]?.stringValue else { return nil }
            func optional(_ key: String) -> String? { json[key]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
            self.init(sessionId: sessionId, text: text, title: optional("title"), directory: optional("directory"),
                      host: optional("host"), updatedAt: json["updatedAt"]?.doubleValue ?? 0)
        }
    }

    /// One append-only journal entry; the app only reads or deletes it.
    public struct JournalEntry: Sendable, Equatable, Identifiable {
        public var id: String
        /// `YYYY-MM-DD` from the key, in the writer's time zone.
        public var day: String
        public var sessionId: String?
        public var text: String
        public var at: Double
        var version: Int

        public init(id: String, day: String, sessionId: String?, text: String, at: Double, version: Int) {
            self.id = id
            self.day = day
            self.sessionId = sessionId
            self.text = text
            self.at = at
            self.version = version
        }

        func key(agentId: String) -> String { "agent/\(agentId)/journal/\(day)/\(id)" }
    }

    /// A Markdown note with `[[links]]`, editable by the user and by any thread.
    public struct Note: Sendable, Equatable, Identifiable {
        public let id: String
        public var title: String
        public var markdown: String
        public var updatedAt: Double
        var version: Int

        public init(id: String = UUID().uuidString.lowercased(), title: String, markdown: String, updatedAt: Double = ServerClock.nowMs(), version: Int = -1) {
            self.id = id.lowercased()
            self.title = title
            self.markdown = markdown
            self.updatedAt = updatedAt
            self.version = version
        }

        public static func key(agentId: String, noteId: String) -> String { "agent/\(agentId)/note/\(noteId.lowercased())" }

        var json: JSONValue {
            ["v": 1, "id": .string(id), "title": .string(title), "markdown": .string(markdown), "updatedAt": .number(updatedAt)]
        }

        func sealed(machineKey: Data) throws -> String {
            try AccountScopedBlob.seal(json, kind: .agentMemory, machineKey: machineKey)
        }
    }

    public var now: [Now]
    public var journal: [JournalEntry]
    public var notes: [Note]
    /// False when one of the listings came back full (see `KVListing`): some records aren't shown.
    public var complete = true

    public init(now: [Now] = [], journal: [JournalEntry] = [], notes: [Note] = []) {
        self.now = now
        self.journal = journal
        self.notes = notes
    }

    public static func prefix(agentId: String) -> String { "agent/\(agentId)/" }

    /// One listing per kind (`now/`, `note/`, `journal/`), so a crowded journal can't hide the notes.
    public static func prefixes(agentId: String) -> [String] { ["now", "note", "journal"].map { "agent/\(agentId)/\($0)/" } }

    init(listings: [JSONValue], machineKey: Data) {
        let items = listings.flatMap { $0["items"]?.arrayValue ?? [] }
        self.init(fromList: ["items": .array(items)], machineKey: machineKey)
        complete = listings.allSatisfy(KVListing.isComplete)
    }

    /// A `GET /v1/kv?prefix=agent/<id>/…` response split by key shape.
    init(fromList response: JSONValue, machineKey: Data) {
        var now: [Now] = [], journal: [JournalEntry] = [], notes: [Note] = []
        for item in response["items"]?.arrayValue ?? [] {
            guard let key = item["key"]?.stringValue, let value = item["value"]?.stringValue, !value.isEmpty else { continue }
            let parts = key.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4, parts[0] == "agent" else { continue }
            let version = item["version"]?.intValue ?? 0
            switch (parts[2], parts.count) {
            case ("now", 4):
                guard let json = AccountScopedBlob.open(value, kind: .agentMemory, machineKey: machineKey),
                      let entry = Now(json: json), entry.sessionId == parts[3] else { continue }
                now.append(entry)
            case ("journal", 5):
                guard let json = AccountScopedBlob.open(value, kind: .agentMemory, machineKey: machineKey),
                      json["v"]?.intValue == 1, let text = json["text"]?.stringValue, !text.isEmpty else { continue }
                journal.append(JournalEntry(id: parts[4], day: parts[3], sessionId: json["sessionId"]?.stringValue,
                                            text: text, at: json["at"]?.doubleValue ?? 0, version: version))
            case ("note", 4):
                guard let json = AccountScopedBlob.open(value, kind: .agentMemory, machineKey: machineKey),
                      json["v"]?.intValue == 1, json["id"]?.stringValue == parts[3] else { continue }
                notes.append(Note(id: parts[3], title: json["title"]?.stringValue ?? "", markdown: json["markdown"]?.stringValue ?? "",
                                  updatedAt: json["updatedAt"]?.doubleValue ?? 0, version: version))
            default:
                continue
            }
        }
        self.now = now.sorted { $0.updatedAt > $1.updatedAt }
        self.journal = journal.sorted { $0.at > $1.at }
        self.notes = notes.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

/// "Export to Obsidian": the memory as a folder of Markdown files. Note bodies are written verbatim
/// and named after their titles, so `[[Title]]` links resolve inside the vault.
public enum AgentMemoryExport {
    public static func folderName(agentName: String) -> String {
        "\(sanitize(agentName).isEmpty ? "Agent" : sanitize(agentName)) Memory"
    }

    /// Relative path → file contents.
    public static func files(agentName: String, memory: AgentMemory, timeZone: TimeZone = .current) -> [String: String] {
        var files: [String: String] = [:]
        var used = Set<String>()
        for note in memory.notes.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            let base = sanitize(note.title).isEmpty ? "Untitled" : sanitize(note.title)
            var name = base, counter = 2
            while used.contains(name.lowercased()) {
                name = "\(base) \(counter)"
                counter += 1
            }
            used.insert(name.lowercased())
            files["Notes/\(name).md"] = note.markdown
        }

        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.timeZone = timeZone
        time.dateFormat = "HH:mm"
        for (day, entries) in Dictionary(grouping: memory.journal, by: \.day) {
            let lines = entries.sorted { $0.at < $1.at }.map { entry in
                "- \(time.string(from: Date(timeIntervalSince1970: entry.at / 1000))) \(entry.text.replacingOccurrences(of: "\n", with: " "))"
            }
            files["Journal/\(day).md"] = "# \(day)\n\n" + lines.joined(separator: "\n") + "\n"
        }

        let threads = memory.now.map { thread in
            let place = [thread.title, [thread.host, thread.directory].compactMap { $0 }.joined(separator: " ")]
                .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
            return "- \(thread.text)\(place.isEmpty ? "" : " — \(place)") (session \(thread.sessionId))"
        }
        files["Now.md"] = "# \(agentName) — now\n\n" + (threads.isEmpty ? "Nothing running." : threads.joined(separator: "\n")) + "\n"
        return files
    }

    /// The export as a directory wrapper for `.fileExporter`.
    public static func fileWrapper(agentName: String, memory: AgentMemory) -> FileWrapper {
        var folders: [String: [String: FileWrapper]] = [:]
        var root: [String: FileWrapper] = [:]
        for (path, contents) in files(agentName: agentName, memory: memory) {
            let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
            let file = FileWrapper(regularFileWithContents: Data(contents.utf8))
            if parts.count == 2 {
                file.preferredFilename = parts[1]
                folders[parts[0], default: [:]][parts[1]] = file
            } else {
                file.preferredFilename = path
                root[path] = file
            }
        }
        for (folder, children) in folders {
            let wrapper = FileWrapper(directoryWithFileWrappers: children)
            wrapper.preferredFilename = folder
            root[folder] = wrapper
        }
        let directory = FileWrapper(directoryWithFileWrappers: root)
        directory.preferredFilename = folderName(agentName: agentName)
        return directory
    }

    /// File-name safe: path separators and characters Obsidian rejects in names become "-".
    static func sanitize(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]")
        return String(title.unicodeScalars.map { forbidden.contains($0) ? "-" : Character($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

import CryptoKit
import Foundation
import Observation
import os

/// App-wide state: credentials, the session list, open transcripts and the realtime connection.
///
/// Sync model (simplest correct form of `docs/protocol.md` for a fresh client): connect the
/// user-scoped socket, then snapshot the session list and catch up open transcripts with
/// `afterSeq`; afterwards apply `update`/`ephemeral` events. Every reconnect repeats the snapshot,
/// so missed events are recovered without the UI's `/v2/changes` machinery.
@MainActor
@Observable
public final class HappierStore {
    public enum Phase: Equatable { case launching, signedOut, ready }
    public enum Connection: Equatable { case connecting, online, offline }

    public struct RPCError: LocalizedError {
        public let message: String
        public let code: String?
        public var errorDescription: String? { message }
    }

    public static let defaultServer = URL(string: "https://happier.nomada.cloud")!

    public internal(set) var phase: Phase = .launching
    public private(set) var connection: Connection = .offline
    public private(set) var server: URL
    /// Observed per session: activity in one session doesn't redraw views showing another.
    public let sessions = KeyedStore<Session>()
    /// Archived sessions opened from the archive or a search; the list refresh (non-archived only)
    /// keeps them so an open archived conversation doesn't vanish.
    @ObservationIgnored private var openedArchivedIds: Set<String> = []
    /// The list as last synced, on disk, and the change cursor it reflects.
    @ObservationIgnored private var snapshots: SessionSnapshotStore?
    @ObservationIgnored private var snapshotCursor: Int?
    /// List syncs run one at a time; a request during one runs once more after it.
    @ObservationIgnored private var sessionSync: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var sessionSyncRequested = false
    @ObservationIgnored private var sessionSyncFull = false
    @ObservationIgnored private var sessionSyncReportsErrors = false
    /// Observed per session, like `sessions`.
    public let transcripts = KeyedStore<Transcript>(isSame: { _, _ in false })
    public let resumingSessions = KeyedStore<Bool>()
    public private(set) var hasOlderMessages: [String: Bool] = [:]
    public private(set) var isLoadingSessions = false
    /// True once the session list has been fetched at least once since sign-in.
    public private(set) var hasLoadedSessions = false
    /// Transcripts whose first page is being fetched.
    public private(set) var loadingTranscripts: Set<String> = []
    /// Daemon machines of this account (refreshed when starting a new session).
    public private(set) var machines: [Machine] = []
    /// Device-local pinned messages for this server/account.
    public private(set) var pins = MessagePins(scope: "signed-out")
    /// Text to seed into a session's composer (restored by rollback or carried into a fork).
    public var draftSeeds: [String: String] = [:]
    /// A session the UI should navigate to (e.g. a freshly created fork).
    public var openRequest: String?
    /// The Tasks list (or one task's detail) to show, e.g. from the My Tasks widget; the Tasks view
    /// consumes it once it is on screen.
    public enum TasksRequest: Equatable, Sendable { case list, task(String) }
    public var tasksRequest: TasksRequest?
    /// An incoming link survives the signed-out screen and account teardown during relay switch.
    public private(set) var pendingSessionLink: SessionLink?
    public private(set) var sessionLinkConfirmation: SessionLink?
    @ObservationIgnored private var sessionLinkTask: Task<Void, Never>?
    public var isOpeningSessionLink: Bool { pendingSessionLink != nil }

    /// One receiver for both the HTTPS landing URL and the native URL scheme.
    @discardableResult
    public func handleSessionLink(_ url: URL) -> Bool {
        guard let link = SessionLink(url: url) else {
            lastError = String(localized: "This Happier link is invalid or unsupported.")
            return false
        }
        cancelSessionLink()
        pendingSessionLink = link
        let target = knownServers.first { RelayList.canonical($0) == RelayList.canonical(link.server) } ?? link.server
        if RelayList.canonical(target) != RelayList.canonical(server), !hasCredentials(for: target) {
            sessionLinkConfirmation = link
        } else {
            beginSessionLink()
        }
        return true
    }

    public func confirmSessionLink() {
        guard sessionLinkConfirmation != nil else { return }
        sessionLinkConfirmation = nil
        beginSessionLink()
    }

    public func cancelSessionLink() {
        sessionLinkTask?.cancel()
        sessionLinkTask = nil
        pendingSessionLink = nil
        sessionLinkConfirmation = nil
    }

    private func beginSessionLink() {
        guard let link = pendingSessionLink else { return }
        let target = knownServers.first { RelayList.canonical($0) == RelayList.canonical(link.server) } ?? link.server
        switchServer(to: target)
        if phase == .launching { restore() }
        resumeSessionLink()
    }

    private func resumeSessionLink() {
        guard phase == .ready, sessionLinkTask == nil, sessionLinkConfirmation == nil,
              let link = pendingSessionLink, RelayList.canonical(server) == RelayList.canonical(link.server) else { return }
        sessionLinkTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.openRelatedSession(link.sessionId)
            guard !Task.isCancelled, self.pendingSessionLink == link else { return }
            self.pendingSessionLink = nil
            self.sessionLinkTask = nil
        }
    }
    /// Server pending queue per open session (queued, blocked and discarded rows).
    public private(set) var pendingQueues: [String: [PendingMessage]] = [:]
    /// Last first-page load failure per session (cleared on retry).
    public private(set) var transcriptErrors: [String: String] = [:]
    /// Sessions whose rows exist but cannot be decrypted with this device's keys.
    public private(set) var undecryptableSessionCount = 0
    public var lastError: String?

    @ObservationIgnored private var credentials: Credentials?
    @ObservationIgnored private var keys: AccountKeys?
    @ObservationIgnored private var api: HappierAPI?
    @ObservationIgnored private var socket: SocketIOClient?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var openSessionIds = OpenSessions()
    @ObservationIgnored private var loadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingFetches: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingFetchDirty: Set<String> = []
    @ObservationIgnored private var pushDevice: PushDevice?
    @ObservationIgnored private var inBackground = false
    @ObservationIgnored private var pendingPushTap: PushTap?
    @ObservationIgnored private let credentialStore = CredentialStore()
    @ObservationIgnored private let log = Logger(subsystem: "dev.happier.apple", category: "sync")

    private var sentFrom: String {
        #if os(macOS)
        "mac"
        #else
        "ios"
        #endif
    }

    public init(server: URL? = nil) {
        let current = server ?? UserDefaults.standard.url(forKey: "happier.server") ?? Self.defaultServer
        let saved = (UserDefaults.standard.stringArray(forKey: Self.knownServersKey) ?? []).compactMap(URL.init(string:))
        self.server = current
        knownServers = RelayList.adding(current, to: saved)
    }

    // MARK: - Account

    public func restore() {
        // Already signed in by a notification action that woke the app before its window.
        guard phase == .launching else { return }
        do {
            if let credentials = try credentialStore.load(server: server) { activate(credentials) } else { phase = .signedOut }
        } catch {
            log.error("credential load failed: \(String(describing: error), privacy: .public)")
            phase = .signedOut
        }
    }

    public func signIn(_ credentials: Credentials, server: URL) throws {
        if let link = pendingSessionLink, RelayList.canonical(link.server) != RelayList.canonical(server) { cancelSessionLink() }
        self.server = server
        UserDefaults.standard.set(server, forKey: "happier.server")
        try credentialStore.save(credentials, server: server)
        rememberServer(server)
        activate(credentials)
    }

    public func signOut() {
        cancelSessionLink()
        if let api, let token = UserDefaults.standard.string(forKey: Self.pushTokenKey) {
            UserDefaults.standard.removeObject(forKey: Self.pushTokenKey)
            Task { try? await api.deletePushToken(token) }
        }
        credentialStore.delete(server: server)
        let snapshots = self.snapshots
        Task { await snapshots?.clear() }
        disconnectAccount()
    }

    // MARK: - Account settings (shared with the React Native app and read by the CLI)

    /// Nil until loaded, or while this device can't read them (`accountSettingsError` says why).
    public private(set) var accountSettings: AccountSettings?
    public private(set) var accountSettingsError: String?
    @ObservationIgnored private var accountSettingsVersion = 0
    @ObservationIgnored private var accountSettingsArePlain = false

    public func refreshAccountSettings() async {
        guard let api else { return }
        do {
            let stored = try await api.accountSettings()
            var plain = stored.content?["t"]?.stringValue == "plain"
            if stored.content == nil { plain = try await !api.accountIsEncrypted() }
            guard let values = AccountSettingsContent.open(stored.content, keys: keys) else {
                accountSettings = nil
                accountSettingsError = String(localized: "This device can't read your account settings.")
                return
            }
            accountSettingsArePlain = plain
            accountSettingsVersion = stored.version
            accountSettings = AccountSettings(values: values)
            accountSettingsError = nil
        } catch {
            accountSettingsError = UserFacingError.message(for: error)
        }
    }

    /// Writes the keys `change` returns over the latest settings. Shown at once, and retried on
    /// top of another device's write (`syncSettings.ts`); put back if it can't be saved.
    public func updateAccountSettings(_ change: (AccountSettings) -> [String: JSONValue]) async {
        guard let api, var current = accountSettings else { return }
        let shown = current
        accountSettings = current.merging(change(current))
        do {
            for _ in 0..<3 {
                let next = current.merging(change(current))
                let content = try AccountSettingsContent.seal(next.values, keys: keys, plain: accountSettingsArePlain)
                switch try await api.writeAccountSettings(content, expectedVersion: accountSettingsVersion) {
                case .saved(let version):
                    accountSettingsVersion = version
                    accountSettings = next
                    return
                case .conflict(let version, let content):
                    guard let values = AccountSettingsContent.open(content, keys: keys) else {
                        throw RPCError(message: String(localized: "This device can't read your account settings."), code: nil)
                    }
                    accountSettingsVersion = version
                    current = AccountSettings(values: values)
                }
            }
            throw RPCError(message: String(localized: "Your settings changed on another device at the same time. Try again."), code: "version-mismatch")
        } catch {
            accountSettings = shown
            report(error)
        }
    }

    // MARK: - Agents (sealed profiles in the account's UserKVStore, `agent/<id>/profile`)

    /// The user's agents by name; empty until loaded.
    public private(set) var agentProfiles: [AgentProfile] = []
    public private(set) var agentProfilesError: String?
    /// False when the agents listing came back full: some agents may be missing from it.
    public private(set) var agentProfilesComplete = true
    @ObservationIgnored private var agentProfileVersions: [String: Int] = [:]
    /// Versions of the legacy `agent/<id>/profile` copies older builds still read; kept in step on write.
    @ObservationIgnored private var legacyAgentProfileVersions: [String: Int] = [:]

    public func agentProfile(id: String?) -> AgentProfile? {
        guard let id else { return nil }
        return agentProfiles.first { $0.id == id }
    }

    public func refreshAgentProfiles() async {
        guard let api else { return }
        guard let machineKey = keys?.content.secretKey else {
            agentProfilesError = String(localized: "Agents need an end-to-end encrypted account.")
            return
        }
        do {
            let listing = try await api.kvList(prefix: AgentProfile.kvPrefix)
            agentProfilesComplete = KVListing.isComplete(listing)
            let current = AgentProfile.records(fromList: listing, machineKey: machineKey)
            // Builds before the move kept profiles under `agent/<id>/profile` (mixed with memory).
            let legacy = AgentProfile.records(fromList: try await api.kvList(prefix: AgentProfile.legacyKvPrefix), machineKey: machineKey)
            legacyAgentProfileVersions = Dictionary(legacy.map { ($0.profile.id, $0.version) }, uniquingKeysWith: { $1 })
            var versions = Dictionary(current.map { ($0.profile.id, $0.version) }, uniquingKeysWith: { $1 })
            let plan = AgentProfile.reconcile(current: current, legacy: legacy)
            for copy in plan.copies {
                // A conflict means another device copied (or edited) it first: the next refresh reads that.
                if case .saved(let saved) = try await api.kvWrite(key: AgentProfile.kvKey(id: copy.profile.id),
                                                                  value: copy.profile.sealed(machineKey: machineKey),
                                                                  version: copy.version) {
                    versions[copy.profile.id] = saved
                }
            }
            agentProfileVersions = versions
            agentProfiles = plan.profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            agentProfilesError = nil
        } catch {
            agentProfilesError = UserFacingError.message(for: error)
        }
    }

    /// Creates or replaces the agent. Another device's write in between wins only for the version:
    /// this edit is written again on top of it.
    @discardableResult
    public func saveAgentProfile(_ profile: AgentProfile) async -> Bool {
        var profile = profile
        profile.updatedAt = ServerClock.nowMs()
        return await writeAgentProfile(id: profile.id, profile: profile)
    }

    /// Keeps the legacy copy in step for builds that still read it; best effort, since the new key is
    /// the source of truth (a conflict means an old build edited it, which the next refresh reconciles).
    private func writeLegacyAgentProfile(id: String, value: String?, api: HappierAPI) async {
        guard let version = legacyAgentProfileVersions[id] else { return }
        if case .saved(let saved) = try? await api.kvWrite(key: AgentProfile.legacyKvKey(id: id), value: value, version: version) {
            legacyAgentProfileVersions[id] = value == nil ? nil : saved
        }
    }

    public func deleteAgentProfile(id: String) async {
        await writeAgentProfile(id: id, profile: nil)
    }

    @discardableResult
    private func writeAgentProfile(id: String, profile: AgentProfile?) async -> Bool {
        guard let api, let machineKey = keys?.content.secretKey else {
            report(RPCError(message: String(localized: "Agents need an end-to-end encrypted account."), code: nil))
            return false
        }
        do {
            let value = try profile?.sealed(machineKey: machineKey)
            var version = agentProfileVersions[id] ?? -1
            for _ in 0..<3 {
                switch try await api.kvWrite(key: AgentProfile.kvKey(id: id), value: value, version: version) {
                case .saved(let saved):
                    agentProfileVersions[id] = saved
                    await writeLegacyAgentProfile(id: id, value: value, api: api)
                    agentProfiles.removeAll { $0.id == id }
                    if let profile {
                        agentProfiles.append(profile)
                        agentProfiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    }
                    return true
                case .conflict(let current, let currentValue):
                    // Deleted elsewhere and deleting here: nothing left to do.
                    if profile == nil, currentValue?.isEmpty ?? true {
                        agentProfiles.removeAll { $0.id == id }
                        agentProfileVersions[id] = current
                        return true
                    }
                    version = current
                }
            }
            throw RPCError(message: String(localized: "This agent changed on another device at the same time. Try again."), code: "version-mismatch")
        } catch {
            report(error)
            return false
        }
    }

    // MARK: - Agent memory (`agent/<id>/now|journal|note/…`, sealed `agent_memory`)

    /// Each agent's memory once loaded, by agent id.
    public private(set) var agentMemories: [String: AgentMemory] = [:]
    public private(set) var agentMemoryError: String?

    public func refreshAgentMemory(agentId: String) async {
        guard let api else { return }
        guard let machineKey = keys?.content.secretKey else {
            agentMemoryError = String(localized: "Agents need an end-to-end encrypted account.")
            return
        }
        do {
            var listings: [JSONValue] = []
            for prefix in AgentMemory.prefixes(agentId: agentId) { listings.append(try await api.kvList(prefix: prefix)) }
            agentMemories[agentId] = AgentMemory(listings: listings, machineKey: machineKey)
            agentMemoryError = nil
        } catch {
            agentMemoryError = UserFacingError.message(for: error)
        }
    }

    /// Creates or replaces a note. A write from another device or thread in between only moves the
    /// version: this edit is written again on top of it.
    @discardableResult
    public func saveAgentNote(_ note: AgentMemory.Note, agentId: String) async -> Bool {
        var note = note
        note.updatedAt = ServerClock.nowMs()
        guard let machineKey = keys?.content.secretKey else {
            report(RPCError(message: String(localized: "Agents need an end-to-end encrypted account."), code: nil))
            return false
        }
        let value: String
        do { value = try note.sealed(machineKey: machineKey) } catch { report(error); return false }
        guard let version = await writeMemoryKey(AgentMemory.Note.key(agentId: agentId, noteId: note.id), value: value,
                                                 version: note.version) else { return false }
        note.version = version
        var memory = agentMemories[agentId] ?? AgentMemory()
        memory.notes.removeAll { $0.id == note.id }
        memory.notes.append(note)
        memory.notes.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        agentMemories[agentId] = memory
        return true
    }

    public func deleteAgentNote(_ note: AgentMemory.Note, agentId: String) async {
        guard await writeMemoryKey(AgentMemory.Note.key(agentId: agentId, noteId: note.id), value: nil, version: note.version) != nil else { return }
        agentMemories[agentId]?.notes.removeAll { $0.id == note.id }
    }

    public func deleteAgentJournalEntry(_ entry: AgentMemory.JournalEntry, agentId: String) async {
        guard await writeMemoryKey(entry.key(agentId: agentId), value: nil, version: entry.version) != nil else { return }
        agentMemories[agentId]?.journal.removeAll { $0.id == entry.id && $0.day == entry.day }
    }

    /// One memory key written at `version`, retried on the server's version after a conflict.
    /// Returns the new version, or nil after reporting the failure.
    private func writeMemoryKey(_ key: String, value: String?, version: Int) async -> Int? {
        guard let api else { return nil }
        var version = version
        do {
            for _ in 0..<3 {
                switch try await api.kvWrite(key: key, value: value, version: version) {
                case .saved(let saved):
                    return saved
                case .conflict(let current, let currentValue):
                    // Already deleted elsewhere and deleting here: done.
                    if value == nil, currentValue?.isEmpty ?? true { return current }
                    version = current
                }
            }
            throw RPCError(message: String(localized: "This memory changed somewhere else at the same time. Try again."), code: "version-mismatch")
        } catch {
            report(error)
            return nil
        }
    }

    // MARK: - Tasks (`task/<id>`, sealed `agent_task`)

    /// The user's and the agents' tasks, once loaded.
    public private(set) var tasks: [AgentTask] = []
    public private(set) var tasksError: String?
    /// False when the tasks listing came back full: some tasks may be missing from it.
    public private(set) var tasksComplete = true

    public func task(id: String?) -> AgentTask? {
        guard let id else { return nil }
        return tasks.first { $0.id == id }
    }

    // MARK: - Live KV updates (tasks, agents, memory)

    /// The account change cursor the KV state shown here is current up to; nil until the first catch-up.
    @ObservationIgnored private var kvCursor: Int?
    @ObservationIgnored private var pendingKVChanges: [AccountKVSync.Change] = []
    @ObservationIgnored private var kvFlush: Task<Void, Never>?

    /// A `kv-batch-update` from the socket: applied in place shortly after, so a burst (an agent
    /// writing its journal and its now) redraws once.
    private func receiveKVUpdate(_ payload: JSONValue) {
        let changes = AccountKVSync.changes(fromUpdate: payload["body"] ?? .null)
        guard !changes.isEmpty else { return }
        if let seq = payload["seq"]?.intValue, let cursor = kvCursor { kvCursor = max(cursor, seq) }
        pendingKVChanges += changes
        guard kvFlush == nil else { return }
        kvFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            let changes = self.pendingKVChanges
            self.pendingKVChanges = []
            self.kvFlush = nil
            if let machineKey = self.keys?.content.secretKey { self.applyKVChanges(changes, machineKey: machineKey) }
        }
    }

    /// Applies changed keys to what is loaded: tasks, agent profiles, and agent memories already open.
    /// A change older than what is shown (an echo of an earlier write) is ignored.
    func applyKVChanges(_ changes: [AccountKVSync.Change], machineKey: Data) {
        var tasks = self.tasks
        var tasksChanged = false
        for change in changes {
            if change.key.hasPrefix(AgentTask.kvPrefix) {
                let id = String(change.key.dropFirst(AgentTask.kvPrefix.count))
                let current = tasks.firstIndex { $0.id == id }
                if let current, tasks[current].version >= change.version { continue }
                if let value = change.value, var task = AgentTask.open(value, machineKey: machineKey), task.id == id {
                    task.version = change.version
                    if let current { tasks[current] = task } else { tasks.append(task) }
                } else if let current {
                    tasks.remove(at: current)
                }
                tasksChanged = true
            } else if let id = AgentProfile.id(fromKey: change.key) {
                let legacy = change.key.hasPrefix(AgentProfile.legacyKvPrefix)
                if legacy {
                    legacyAgentProfileVersions[id] = change.value == nil ? nil : change.version
                    // Only an older build's agent this app doesn't have yet is shown from the old key.
                    guard agentProfiles.contains(where: { $0.id == id }) == false else { continue }
                } else if let known = agentProfileVersions[id], known >= change.version {
                    continue
                }
                agentProfiles.removeAll { $0.id == id }
                if let value = change.value, let profile = AgentProfile.open(value, machineKey: machineKey), profile.id == id {
                    agentProfiles.append(profile)
                    agentProfiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    if !legacy { agentProfileVersions[id] = change.version }
                } else if !legacy {
                    agentProfileVersions[id] = nil
                }
            } else if change.key.hasPrefix("agent/") {
                let agentId = change.key.split(separator: "/").dropFirst().first.map(String.init) ?? ""
                guard let memory = agentMemories[agentId] else { continue }
                agentMemories[agentId] = memory.applying(change, machineKey: machineKey)
            }
        }
        if tasksChanged { self.tasks = tasks }
    }

    func setAgentMemoryForTests(_ memory: AgentMemory, agentId: String) {
        agentMemories[agentId] = memory
    }

    /// After a reconnect or coming back to the foreground: nothing to read when the KV store didn't
    /// change since `kvCursor`; otherwise only the prefixes shown here are read again.
    public func catchUpAccountKV() async {
        guard let api else { return }
        guard let cursor = kvCursor else {
            // First time: the lists are read when shown; start following changes from now.
            kvCursor = try? await api.changesCursor()
            return
        }
        do {
            var after = cursor
            var touched = false
            while true {
                guard let response = try await api.changes(after: after, limit: 500) else {
                    touched = true // The cursor is gone: read what is shown again.
                    after = (try? await api.changesCursor()) ?? after
                    break
                }
                let page = AccountKVSync.page(response)
                touched = touched || page.touchedKV
                let next = page.nextCursor ?? after
                guard page.count == 500, next > after else {
                    after = max(next, after)
                    break
                }
                after = next
            }
            kvCursor = after
            guard touched else { return }
            await refreshTasks()
            await refreshAgentProfiles()
            for agentId in agentMemories.keys { await refreshAgentMemory(agentId: agentId) }
        } catch {
            logBackground(error, "account kv catch-up")
        }
    }

    public func refreshTasks() async {
        guard let api else { return }
        guard let machineKey = keys?.content.secretKey else {
            tasksError = String(localized: "Tasks need an end-to-end encrypted account.")
            return
        }
        do {
            let listing = try await api.kvList(prefix: AgentTask.kvPrefix)
            tasksComplete = KVListing.isComplete(listing)
            tasks = AgentTask.records(fromList: listing, machineKey: machineKey)
            tasksError = nil
        } catch {
            tasksError = UserFacingError.message(for: error)
        }
    }

    /// Stores a new task.
    @discardableResult
    public func createTask(_ task: AgentTask) async -> Bool {
        await writeTask(task, update: nil) != nil
    }

    /// Applies `update` to the stored task. When an agent or another device changed it first, the
    /// update is applied again on their copy, so their comments and fields aren't lost.
    @discardableResult
    public func updateTask(id: String, _ update: AgentTask.Update) async -> AgentTask? {
        guard let current = task(id: id), !update.isEmpty else { return task(id: id) }
        // Handing it to someone else cancels a pending start made for the previous assignee.
        let update = current.scheduleAware(update)
        guard let saved = await writeTask(current, update: update) else { return nil }
        if case .some(.none) = update.scheduledStart, let id = current.scheduledStart?.automationId {
            do { try await api?.deleteTaskAutomation(id: id) } catch { report(error) }
        }
        // A pending start on the task's machine follows it to the new one.
        if let start = saved.scheduledStart, let automationId = start.automationId, saved.assignee.agentId != nil,
           update.machineId != nil, let machineId = saved.machineId, machineId != current.machineId {
            do { try await api?.moveTaskAutomation(id: automationId, machineId: machineId) } catch { report(error) }
        }
        // Closing a repeating task pauses its Automations: they must not keep firing on a closed task.
        if let paused = current.recurrenceToPause(closingWith: update) {
            return await saveRecurrence(taskId: id, paused) ?? saved
        }
        // A repeating task's Automations carry its machine, folder and agent: keep them in step.
        if let recurrence = saved.recurrence, update.machineId != nil || update.directory != nil || update.assignee != nil {
            do {
                _ = try await syncRecurrenceAutomations(task: saved, recurrence: recurrence, previous: recurrence)
            } catch {
                report(error)
            }
        }
        return saved
    }

    /// The same change to several tasks (the list's Select): each is written as `updateTask` does.
    public func updateTasks(ids: [String], _ update: AgentTask.Update) async {
        for id in ids { await updateTask(id: id, update) }
    }

    // MARK: Recurring tasks (one Automation per rule, `/v2/automations`)

    /// What a recurring task needs before its rules can fire: an agent, a machine and a folder.
    public func recurrenceProblem(for task: AgentTask) -> String? {
        if case .session(let id, _) = task.assignee {
            return recurrenceTarget(for: task) == nil
                ? String(localized: "This session isn't available here; open it once so its machine is known.")
                : nil
        }
        guard let agentId = task.assignee.agentId, agentProfile(id: agentId) != nil else {
            return String(localized: "Assign the task to an agent or a session first: it works each occurrence.")
        }
        guard task.machineId?.isEmpty == false else { return String(localized: "Choose the machine the task runs on.") }
        guard task.directory?.isEmpty == false else { return String(localized: "Choose the folder the agent works in.") }
        return nil
    }

    /// Where a repeating task's Automations run: the task's machine and folder for an agent, or the
    /// assigned session's own machine and folder (the daemon sends each occurrence to that session).
    func recurrenceTarget(for task: AgentTask) -> (machineId: String, directory: String, providerId: String)? {
        switch task.assignee {
        case .session(let id, _):
            guard let session = sessions[id], let machineId = session.machineId, let path = session.path else { return nil }
            return (machineId, path, session.agentId ?? "claude")
        case .agent(let id, _, _):
            guard let agent = agentProfile(id: id), let machineId = task.machineId, let directory = task.directory else { return nil }
            return (machineId, directory, agent.providerId)
        case .user:
            return nil
        }
    }

    /// Saves the task's recurrence (nil removes it), creating, updating, pausing or deleting one
    /// Automation per rule first, so the server only fires what the task describes.
    @discardableResult
    public func saveRecurrence(taskId: String, _ recurrence: TaskRecurrence?) async -> AgentTask? {
        guard let api, let current = task(id: taskId) else { return nil }
        let previous = current.recurrence
        guard var next = recurrence else {
            do {
                for rule in previous?.rules ?? [] { if let id = rule.automationId { try await api.deleteTaskAutomation(id: id) } }
            } catch {
                report(error)
                return nil
            }
            return await writeTask(current, update: AgentTask.Update(recurrence: .some(nil)))
        }
        if let problem = recurrenceProblem(for: current) {
            report(RPCError(message: problem, code: nil))
            return nil
        }
        var created: [String] = []
        do {
            (next, created) = try await syncRecurrenceAutomations(task: current, recurrence: next, previous: previous)
            let kept = Set(next.rules.compactMap(\.automationId))
            for rule in previous?.rules ?? [] {
                if let id = rule.automationId, !kept.contains(id) { try await api.deleteTaskAutomation(id: id) }
            }
        } catch {
            for id in created { try? await api.deleteTaskAutomation(id: id) }
            report(error)
            return nil
        }
        guard let saved = await writeTask(current, update: AgentTask.Update(recurrence: .some(next))) else {
            // The task didn't take the new rules: don't leave Automations firing for them.
            for id in created { try? await api.deleteTaskAutomation(id: id) }
            return nil
        }
        return saved
    }

    /// Fires the task's first rule now (the daemon still skips it while an occurrence is running).
    public func runRecurrenceNow(taskId: String) async {
        guard let api, let id = task(id: taskId)?.recurrence?.rules.compactMap(\.automationId).first else { return }
        do {
            try await api.runTaskAutomationNow(id: id)
        } catch {
            report(error)
        }
    }

    /// Creates each rule's Automation that doesn't exist yet and updates the rest (schedule, machine,
    /// template); pauses or resumes them when that changed. Returns the rules with their ids and the
    /// Automations it created.
    private func syncRecurrenceAutomations(task: AgentTask, recurrence: TaskRecurrence,
                                           previous: TaskRecurrence?) async throws -> (TaskRecurrence, [String]) {
        guard let api, let machineKey = keys?.content.secretKey else {
            throw RPCError(message: String(localized: "Tasks need an end-to-end encrypted account."), code: nil)
        }
        guard let target = recurrenceTarget(for: task) else {
            throw RPCError(message: recurrenceProblem(for: task) ?? "", code: nil)
        }
        let machineId = target.machineId, directory = target.directory
        var next = recurrence
        var created: [String] = []
        for index in next.rules.indices {
            let rule = next.rules[index]
            let template = try TaskRecurrence.automationTemplateCiphertext(taskId: task.id, ruleId: rule.id, directory: directory,
                                                                          providerId: target.providerId, machineKey: machineKey)
            if let id = rule.automationId {
                try await api.updateTaskAutomation(id: id, rule: rule, timezone: next.timezone, machineId: machineId, templateCiphertext: template)
                if (previous?.paused ?? false) != next.paused { try await api.setTaskAutomation(id: id, paused: next.paused) }
            } else {
                let id = try await api.createTaskAutomation(taskId: task.id, rule: rule, timezone: next.timezone, enabled: !next.paused,
                                                            machineId: machineId, templateCiphertext: template)
                created.append(id)
                next.rules[index].automationId = id
            }
        }
        return (next, created)
    }

    public func deleteTask(id: String) async {
        guard let api, let current = task(id: id) else { return }
        var version = current.version
        do {
            for _ in 0..<3 {
                switch try await api.kvWrite(key: AgentTask.kvKey(id: id), value: nil, version: version) {
                case .saved:
                    tasks.removeAll { $0.id == id }
                    return
                case .conflict(let latest, let value):
                    if value?.isEmpty ?? true {
                        tasks.removeAll { $0.id == id }
                        return
                    }
                    version = latest
                }
            }
            throw RPCError(message: String(localized: "This task changed somewhere else at the same time. Try again."), code: "version-mismatch")
        } catch {
            report(error)
        }
    }

    /// "Assign to…": only who it's for. Nothing starts and the status stays.
    @discardableResult
    public func assignTask(id: String, to assignee: AgentTask.Assignee) async -> AgentTask? {
        await updateTask(id: id, .assigning(assignee))
    }

    /// "Start Now" for a task assigned to an agent: starts a session as that agent in `directory` on
    /// `machineId`, whose first message carries the task, links it and puts the task in progress.
    public func startTaskNow(id: String, machineId: String, directory: String, approveNewDirectory: Bool = false) async -> SpawnOutcome {
        guard let current = task(id: id), let agentId = current.assignee.agentId, let agent = agentProfile(id: agentId) else {
            return .failed(String(localized: "Assign the task to one of your agents first."))
        }
        // Every start of a task runs with the task's own mode (YOLO unless it says otherwise).
        let outcome = await createSession(machineId: machineId, directory: directory, agentId: agent.providerId, permissionMode: current.permissionMode,
                                          modelId: agent.modelId, effort: agent.effort, agent: agent,
                                          firstMessage: current.assignmentMessage(agentName: agent.name),
                                          approveNewDirectory: approveNewDirectory)
        if case .created(let sessionId) = outcome {
            await markStarted(id: id, sessionId: sessionId)
            await rename(sessionId, to: current.title)
        }
        return outcome
    }

    /// "Start Now" for a task assigned to a session: sends that session the task as a message (the
    /// composer's path, which also reaches a session that isn't running), links it and puts the task
    /// in progress. False after reporting why not.
    public func startTaskInSession(id: String) async -> Bool {
        guard let current = task(id: id), let sessionId = current.assignee.sessionId else { return false }
        guard sessions[sessionId] != nil,
              await send(current.assignmentMessage(agentName: nil), to: sessionId, permissionMode: current.permissionMode) else { return false }
        await markStarted(id: id, sessionId: sessionId)
        return true
    }

    /// Links the session that started the task and marks it in progress; a pending start is no
    /// longer needed (`updateTask` deletes its Automation).
    private func markStarted(id: String, sessionId: String) async {
        var update = AgentTask.Update.started(sessionId: sessionId)
        if task(id: id)?.scheduledStart != nil { update.scheduledStart = .some(nil) }
        await updateTask(id: id, update)
    }

    // MARK: Scheduled start (one Automation, `/v2/automations`)

    /// Where and as which agent a scheduled start runs: the agent's engine, machine and folder, or the
    /// assigned session's own.
    private func scheduledStartPlace(for task: AgentTask) -> (machineId: String, directory: String, providerId: String)? {
        if let sessionId = task.assignee.sessionId {
            guard let session = sessions[sessionId], let machineId = session.machineId,
                  let directory = session.path ?? task.directory, !directory.isEmpty else { return nil }
            return (machineId, directory, session.agentId ?? "claude")
        }
        guard let agentId = task.assignee.agentId, let agent = agentProfile(id: agentId),
              let machineId = task.machineId, !machineId.isEmpty, let directory = task.directory, !directory.isEmpty else { return nil }
        return (machineId, directory, agent.providerId)
    }

    /// What a task needs before it can be scheduled; nil when it can be.
    public func scheduleProblem(for task: AgentTask) -> String? {
        if let sessionId = task.assignee.sessionId {
            guard let session = sessions[sessionId] else { return String(localized: "The task's session isn't on this device anymore.") }
            guard session.machineId != nil else { return String(localized: "The task's session isn't linked to a machine.") }
            guard (session.path ?? task.directory)?.isEmpty == false else { return String(localized: "Choose the folder the agent works in.") }
            return nil
        }
        guard let agentId = task.assignee.agentId, agentProfile(id: agentId) != nil else {
            return String(localized: "Assign the task to one of your agents or a session first.")
        }
        guard task.machineId?.isEmpty == false else { return String(localized: "Choose the machine the task runs on.") }
        guard task.directory?.isEmpty == false else { return String(localized: "Choose the folder the agent works in.") }
        return nil
    }

    /// The engine a scheduled start runs, for the Consumer Terms warning.
    public func scheduledStartProviderId(for task: AgentTask) -> String? {
        scheduledStartPlace(for: task)?.providerId
    }

    /// Starts the task once at `at` (in `timezone`): moves the pending start, or creates its Automation
    /// and records it on the task.
    @discardableResult
    public func scheduleTaskStart(id: String, at: Date, timezone: String = TimeZone.current.identifier) async -> AgentTask? {
        guard let api, let machineKey = keys?.content.secretKey, let current = task(id: id) else { return nil }
        var start = TaskScheduledStart(at: (at.timeIntervalSince1970 * 1000).rounded(.down), timezone: timezone)
        if let pending = current.scheduledStart, let automationId = pending.automationId {
            start.automationId = automationId
            do { try await api.rescheduleStartAutomation(id: automationId, start: start) } catch {
                report(error)
                return nil
            }
            return await writeTask(current, update: AgentTask.Update(scheduledStart: .some(start)))
        }
        if let problem = scheduleProblem(for: current) {
            report(RPCError(message: problem, code: nil))
            return nil
        }
        guard let place = scheduledStartPlace(for: current) else { return nil }
        do {
            let template = try TaskScheduledStart.automationTemplateCiphertext(taskId: current.id, directory: place.directory,
                                                                              providerId: place.providerId, machineKey: machineKey)
            start.automationId = try await api.createScheduledStartAutomation(taskId: current.id, start: start, machineId: place.machineId,
                                                                             templateCiphertext: template)
        } catch {
            report(error)
            return nil
        }
        guard let saved = await writeTask(current, update: AgentTask.Update(scheduledStart: .some(start))) else {
            // The task didn't take it: don't leave an Automation firing for it.
            if let created = start.automationId { try? await api.deleteTaskAutomation(id: created) }
            return nil
        }
        return saved
    }

    /// Cancels the pending start: deletes its Automation, then removes it from the task.
    @discardableResult
    public func cancelScheduledStart(id: String) async -> AgentTask? {
        guard let api, let current = task(id: id), let pending = current.scheduledStart else { return task(id: id) }
        if let automationId = pending.automationId {
            do { try await api.deleteTaskAutomation(id: automationId) } catch {
                report(error)
                return nil
            }
        }
        return await writeTask(current, update: AgentTask.Update(scheduledStart: .some(nil)))
    }

    /// Writes `task` (new when `update` is nil) at its version, re-applying `update` on the server's
    /// copy after a conflict. Returns the stored task, or nil after reporting the failure.
    private func writeTask(_ task: AgentTask, update: AgentTask.Update?) async -> AgentTask? {
        guard let api, let machineKey = keys?.content.secretKey else {
            report(RPCError(message: String(localized: "Tasks need an end-to-end encrypted account."), code: nil))
            return nil
        }
        var base = task
        do {
            for _ in 0..<3 {
                var next = update.map { base.applying($0, now: ServerClock.nowMs()) } ?? base
                switch try await api.kvWrite(key: AgentTask.kvKey(id: next.id), value: try next.sealed(machineKey: machineKey), version: base.version) {
                case .saved(let version):
                    next.version = version
                    tasks.removeAll { $0.id == next.id }
                    tasks.append(next)
                    return next
                case .conflict(let latest, let value):
                    guard update != nil, let value, var current = AgentTask.open(value, machineKey: machineKey) else {
                        throw RPCError(message: String(localized: "This task was changed or deleted somewhere else. Refresh and try again."),
                                       code: "version-mismatch")
                    }
                    current.version = latest
                    base = current
                }
            }
            throw RPCError(message: String(localized: "This task changed somewhere else at the same time. Try again."), code: "version-mismatch")
        } catch {
            report(error)
            return nil
        }
    }

    // MARK: - Relays

    private static let knownServersKey = "happier.knownServers"
    /// Relays this device has used; each keeps its own credentials in the Keychain.
    public private(set) var knownServers: [URL]

    private func rememberServer(_ url: URL) {
        knownServers = RelayList.adding(url, to: knownServers)
        UserDefaults.standard.set(knownServers.map(\.absoluteString), forKey: Self.knownServersKey)
    }

    /// Whether this device holds a sign-in for `url`.
    public func hasCredentials(for url: URL) -> Bool {
        (try? credentialStore.load(server: url)) != nil
    }

    /// Moves to another relay without signing out of this one: its saved sign-in is used when
    /// there is one, otherwise the sign-in screen opens on that relay.
    public func switchServer(to url: URL) {
        if let link = pendingSessionLink, RelayList.canonical(link.server) != RelayList.canonical(url) { cancelSessionLink() }
        guard RelayList.canonical(url) != RelayList.canonical(server) else { return }
        let saved = try? credentialStore.load(server: url)
        if phase == .ready { disconnectAccount() }
        server = url
        UserDefaults.standard.set(url, forKey: "happier.server")
        rememberServer(url)
        if let saved { activate(saved) } else { phase = .signedOut }
    }

    public struct RelayStatus: Sendable {
        public let responseTime: Duration?
        public let build: String?
    }

    /// Reachability (round trip to `/health`) and build of a relay, from its public routes.
    public nonisolated static func relayStatus(_ url: URL) async -> RelayStatus {
        let http = HTTPClient(baseURL: url)
        let clock = ContinuousClock()
        let start = clock.now
        let healthy = (try? await http.get("/health")) != nil
        let elapsed = start.duration(to: clock.now)
        let version = try? await http.get("/v1/version")
        return RelayStatus(responseTime: healthy ? elapsed : nil, build: version.flatMap(RelayList.build(fromVersion:)))
    }

    /// Drops the live connection and in-memory state of the current account (credentials stay).
    private func disconnectAccount() {
        syncTask?.cancel()
        let socket = self.socket
        Task { await socket?.disconnect() }
        credentials = nil
        keys = nil
        api = nil
        self.socket = nil
        outgoingSends.values.forEach { $0.isCancelled = true }
        outgoingSends = [:]
        failedSends = [:]
        for localId in uploadProgress.keys { uploadObserver?.uploadDidFinish(localId: localId, success: false) }
        uploadProgress = [:]
        uploadSessionIds = [:]
        tokenUsageGeneration = UUID()
        tokenUsageTask?.cancel()
        tokenUsageTask = nil
        tokenUsageQueue = []
        tokenUsageInFlight = nil
        sessionTokenUsage.removeAll()
        sessions.removeAll()
        transcripts.removeAll()
        resumingSessions.removeAll()
        hasLoadedSessions = false
        pendingQueues = [:]
        draftSeeds = [:]
        openRequest = nil
        pinnedSessionIds = []
        deleteRequest = nil
        deletedSessionIds = []
        accountSettings = nil
        accountSettingsError = nil
        accountSettingsVersion = 0
        agentProfiles = []
        agentProfilesError = nil
        agentProfileVersions = [:]
        legacyAgentProfileVersions = [:]
        kvCursor = nil
        pendingKVChanges = []
        kvFlush?.cancel()
        kvFlush = nil
        agentMemories = [:]
        agentMemoryError = nil
        tasks = []
        tasksError = nil
        tasksComplete = true
        machines = []
        openSessionIds = OpenSessions()
        draftStates.values.forEach { $0.upload?.cancel() }
        draftStates = [:]
        pendingDraftsKey = nil
        syncedDrafts.removeAll()
        loadTasks.values.forEach { $0.cancel() }
        loadTasks = [:]
        fileIndexes = [:]
        fileIndexListings = [:]
        snapshots = nil
        snapshotCursor = nil
        sessionSync?.task.cancel()
        sessionSync = nil
        connection = .offline
        phase = .signedOut
    }

    /// Signs in another device that shows the "Link with Another Device" QR: after checking with the
    /// relay that this device's key is still the Account's, its credentials go sealed for that device.
    public func approveDeviceLink(_ link: String) async throws {
        guard let request = AccountLinkRequest(link) else {
            throw RPCError(message: String(localized: "That isn't a Happier link code. Scan the code on the device you want to sign in."), code: "invalid_link")
        }
        guard let api, let credentials, let accountId = credentials.accountId else {
            throw RPCError(message: String(localized: "Sign in on this device first."), code: "signed_out")
        }
        let encrypted = try await api.accountIsEncrypted()
        if encrypted {
            guard let profile = try await api.accountLinkProfile(accountId: accountId) else { throw AccountKeyProvisioning.Unavailable() }
            try AccountKeyProvisioning.verify(encrypted: true, account: profile, credentials: credentials)
        }
        try await api.approveAccountLink(publicKey: request.publicKey, response: try credentials.accountLinkResponse(for: request))
    }

    /// The 32-byte recovery secret, when this device holds it (for showing the backup key).
    public var recoverySecret: Data? { keys?.masterSecret }
    public var accountId: String? { credentials?.accountId }

    private func activate(_ credentials: Credentials) {
        self.credentials = credentials
        do { keys = try credentials.accountKeys() } catch {
            log.error("invalid key material: \(String(describing: error), privacy: .public)")
            keys = nil
        }
        api = HappierAPI(server: server, token: credentials.token)
        Task { await registerPushToken() }
        Task { await refreshAccountSettings() }
        let scope = "\(server.host() ?? server.absoluteString)/\(credentials.accountId ?? "account")"
        pins = MessagePins(scope: scope)
        pendingDraftsKey = "happier.pendingDrafts.\(scope)"
        restorePendingDrafts()
        snapshots = SessionSnapshotStore(directory: Self.cacheDirectory, scope: scope)
        snapshotCursor = nil
        phase = .ready
        syncTask?.cancel()
        syncTask = Task { await runSync() }
        resumeSessionLink()
    }

    // MARK: - Session list

    public var sessionList: [Session] {
        let now = Date.now
        return sessions.values.filter(\.isUserFacing)
            .map { ($0, listDate($0, now: now)) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Where the list puts a session: its last activity, held still while it works (`RestingDates`).
    public func listDate(_ session: Session, now: Date = .now) -> Date {
        restingDates.date(for: session, now: now)
    }

    @ObservationIgnored private var restingDates = RestingDates()

    /// Brings the session list up to date: only the sessions changed since the last sync when the
    /// account's change cursor allows it, otherwise (no snapshot yet, cursor gone, most of the
    /// list changed, pull to refresh) the whole list. Background syncs only log failures; a
    /// user-initiated one (pull to refresh) shows them.
    public func refreshSessions(userInitiated: Bool = false) async {
        sessionSyncRequested = true
        if userInitiated {
            sessionSyncFull = true
            sessionSyncReportsErrors = true
        }
        if let running = sessionSync {
            await running.task.value
            return
        }
        let id = UUID()
        let task = Task {
            while sessionSyncRequested, !Task.isCancelled {
                sessionSyncRequested = false
                let full = sessionSyncFull
                let reports = sessionSyncReportsErrors
                sessionSyncFull = false
                sessionSyncReportsErrors = false
                await syncSessions(full: full, reportErrors: reports)
            }
            // No suspension since the last check: a request can't slip in between. A loop cancelled
            // by a sign-out must not clear the next account's.
            if sessionSync?.id == id { sessionSync = nil }
        }
        sessionSync = (id, task)
        await task.value
    }

    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Happier")
    }

    /// The list from the last launch, shown while the first sync runs.
    private func showCachedSessions() async {
        guard !hasLoadedSessions, let snapshots else { return }
        let clock = ContinuousClock()
        let started = clock.now
        guard let snapshot = await snapshots.load() else { return }
        let keys = self.keys
        let decoded = await Task.detached(priority: .userInitiated) { Self.decodeSessions(snapshot.rows, keys: keys) }.value
        guard !hasLoadedSessions, self.snapshots === snapshots else { return }
        var next = decoded.sessions
        for id in openedArchivedIds where next[id] == nil { next[id] = sessions[id] }
        sessions.replaceAll(with: next)
        undecryptableSessionCount = decoded.failures
        snapshotCursor = snapshot.cursor
        hasLoadedSessions = true
        log.notice("sessions: \(decoded.sessions.count, privacy: .public) from cache in \(clock.now - started, privacy: .public)")
        Task { await refreshPinnedSessions() }
        Task { await handlePendingPushTap() }
    }

    private func syncSessions(full: Bool, reportErrors: Bool) async {
        guard api != nil, snapshots != nil else { return }
        isLoadingSessions = true
        defer { isLoadingSessions = false }
        let clock = ContinuousClock()
        let started = clock.now
        do {
            if !full, let cursor = snapshotCursor, let changed = try await syncChangedSessions(since: cursor) {
                log.notice("sessions: \(changed, privacy: .public) changed, synced in \(clock.now - started, privacy: .public)")
            } else {
                let count = try await syncAllSessions()
                log.notice("sessions: full list of \(count, privacy: .public) in \(clock.now - started, privacy: .public)")
            }
        } catch {
            if reportErrors { report(error) } else { logBackground(error, "session list sync") }
        }
    }

    /// The whole list (`/v2/sessions`), saved with the cursor read just before it so the next sync
    /// replays anything that changed while it downloaded.
    private func syncAllSessions() async throws -> Int {
        guard let api, let snapshots else { return 0 }
        let cursor = try? await api.changesCursor()
        let rows = try await api.listSessions()
        let keys = self.keys
        let decoded = await Task.detached(priority: .userInitiated) { Self.decodeSessions(rows, keys: keys) }.value
        guard self.snapshots === snapshots else { return 0 }
        if decoded.failures > 0 { log.notice("\(decoded.failures) sessions could not be decrypted") }
        undecryptableSessionCount = decoded.failures
        var next = decoded.sessions
        for id in openedArchivedIds where next[id] == nil { next[id] = sessions[id] }
        sessions.replaceAll(with: next)
        hasLoadedSessions = true
        snapshotCursor = cursor
        didUpdateSessions(Set(next.keys))
        await snapshots.save(SessionSnapshot(rows: rows, cursor: cursor))
        return rows.count
    }

    /// Fetches only the sessions changed since `cursor`. Nil when that can't catch up (the cursor is
    /// gone) or isn't worth it (most of the list changed: one list download beats that many).
    private func syncChangedSessions(since cursor: Int) async throws -> Int? {
        guard let api, let snapshots else { return nil }
        let pageSize = 500 // `/v2/changes` maximum
        var after = cursor
        var ids: [String] = []
        while true {
            guard let response = try await api.changes(after: after, limit: pageSize) else { return nil }
            let page = SessionChanges.page(response)
            ids += page.sessionIds.filter { !ids.contains($0) }
            if ids.count * 2 > max(sessions.count, 1) { return nil }
            let next = page.nextCursor ?? after
            guard page.count == pageSize, next > after else {
                after = max(next, after)
                break
            }
            after = next
        }
        guard !ids.isEmpty else {
            snapshotCursor = after
            return 0
        }
        // Up to four at a time, well inside the session-detail rate limit.
        var changed: [String: JSONValue] = [:]
        var removed = Set<String>()
        for batch in stride(from: 0, to: ids.count, by: 4).map({ Array(ids[$0..<min($0 + 4, ids.count)]) }) {
            try await withThrowingTaskGroup(of: (String, JSONValue?).self) { group in
                for id in batch {
                    group.addTask {
                        do {
                            return (id, try await api.session(id: id))
                        } catch let error as HTTPClient.ServerError where error.status == 404 {
                            return (id, nil)
                        }
                    }
                }
                for try await (id, row) in group {
                    if let row { changed[id] = row } else { removed.insert(id) }
                }
            }
        }
        let keys = self.keys
        let rows = Array(changed.values)
        let decoded = await Task.detached(priority: .userInitiated) { Self.decodeSessions(rows, keys: keys) }.value
        guard self.snapshots === snapshots else { return nil }
        for id in removed where !openedArchivedIds.contains(id) {
            sessions[id] = nil
            transcripts[id] = nil
        }
        for (id, session) in decoded.sessions {
            if session.archivedAt != nil, !openedArchivedIds.contains(id) {
                sessions[id] = nil
            } else {
                sessions[id] = session
            }
        }
        snapshotCursor = after
        didUpdateSessions(Set(decoded.sessions.keys))
        if let snapshot = await snapshots.load() {
            await snapshots.save(snapshot.applying(changed: changed, removed: removed, cursor: after))
        }
        return ids.count
    }

    private func didUpdateSessions(_ ids: Set<String>) {
        Task { await refreshPinnedSessions() }
        Task { await handlePendingPushTap() }
        for id in ids where transcripts[id] != nil {
            if let state = sessions[id]?.agentState { transcripts[id]?.apply(agentState: state) }
        }
        // A conversation opened before its session was known (a cold start, a notification tap)
        // loads as soon as it is.
        for id in ids where openSessionIds.contains(id) && transcripts[id]?.isLoaded != true && transcriptErrors[id] == nil {
            startLoading(id)
        }
    }

    private nonisolated static func decodeSessions(_ rows: [JSONValue], keys: AccountKeys?) -> (sessions: [String: Session], failures: Int) {
        var sessions: [String: Session] = [:]
        var failures = 0
        for row in rows {
            if let session = try? Session(row: row, keys: keys) { sessions[session.id] = session } else { failures += 1 }
        }
        return (sessions, failures)
    }

    // MARK: - App lifecycle

    /// iOS freezes networking while the app is in the background: close the socket cleanly so
    /// nothing is left half-open, and reconnect + resync as soon as the app is back.
    /// Set while something in the background still needs new messages (reading them aloud as
    /// they arrive): the relay connection stays open instead of closing with the app minimized.
    public var keepsConnectionInBackground = false {
        didSet {
            if !keepsConnectionInBackground, inBackground, uploadProgress.isEmpty { suspendForBackground() }
        }
    }

    public func appDidEnterBackground() {
        guard phase == .ready else { return }
        inBackground = true
        flushDrafts()
        // Uploads in flight keep the socket (and the app, through a background task) alive; the
        // connection is closed once they finish.
        guard uploadProgress.isEmpty, !keepsConnectionInBackground else { return }
        suspendForBackground()
    }

    private func suspendForBackground() {
        syncTask?.cancel()
        syncTask = nil
        let socket = self.socket
        Task { await socket?.disconnect() }
        connection = .offline
    }

    public func appDidBecomeActive() {
        inBackground = false
        guard phase == .ready, syncTask == nil else { return }
        syncTask = Task { await runSync() }
    }

    // MARK: - Realtime

    private func runSync() async {
        var backoff: Duration = .seconds(1)
        await showCachedSessions()
        await refreshSessions()
        while !Task.isCancelled, let token = credentials?.token {
            connection = .connecting
            let socket = SocketIOClient(
                serverURL: server, path: "/v1/updates",
                auth: ["token": .string(token), "clientType": "user-scoped", "clientPurpose": "sync"])
            self.socket = socket
            registeredBrowserMethods = []
            await socket.setRequestHandler { [weak self] name, args in
                guard name == "rpc-request", let payload = args.first else { return nil }
                return await self?.answerSocketRequest(payload)
            }
            do {
                try await socket.connect()
                connection = .online
                backoff = .seconds(1)
                tokenUsageQueue.formUnion(sessionTokenUsage.keys)
                Task { await drainTokenUsageQueue() }
                await syncDeviceBrowserRegistrations()
                await refreshSessions()
                // Tasks, agents and memory changed while offline arrive through the change cursor.
                Task { await catchUpAccountKV() }
                for id in openSessionIds {
                    startLoading(id)
                    refreshRunnerStatus(id)
                    await loadDraft(id)
                }
                // Text typed while offline, or before the app was closed, goes up now.
                flushDrafts()
                for await event in socket.events { await handle(event) }
            } catch let error as SocketIOClient.ConnectError where error.message == "invalid-token" {
                log.error("token rejected; signing out")
                signOut()
                return
            } catch {
                log.notice("socket failed: \(String(describing: error), privacy: .public)")
            }
            connection = .offline
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(30))
        }
    }

    private func handle(_ event: SocketIOClient.Event) async {
        guard case .event(let name, let args) = event, let payload = args.first else { return }
        switch name {
        case "update":
            receiveKVUpdate(payload)
            await handleUpdate(payload["body"] ?? .null)
        case "ephemeral":
            if payload["type"]?.stringValue == "usage", let id = payload["id"]?.stringValue,
               sessionTokenUsage[id] != nil || tokenUsageInFlight == id || tokenUsageQueue.contains(id) {
                tokenUsageQueue.insert(id)
                Task { await drainTokenUsageQueue() }
            } else if payload["type"]?.stringValue == "session-draft-updated" || payload["sessionDraft"]?.boolValue == true {
                handleDraftHint(payload)
            } else if payload["type"]?.stringValue == "machine-activity", let id = payload["id"]?.stringValue {
                if let index = machines.firstIndex(where: { $0.id == id }) { machines[index].apply(activity: payload) }
            } else if payload["type"]?.stringValue == "activity", let id = payload["id"]?.stringValue,
                      let session = sessions[id], let updated = session.applying(activity: payload) {
                sessions[id] = updated
                // A runner can only be restarted between turns; re-check when a turn ends.
                if session.thinking, !updated.thinking, openSessionIds.contains(id) { refreshRunnerStatus(id) }
            }
        default:
            break
        }
    }

    private func handleUpdate(_ body: JSONValue) async {
        switch body["t"]?.stringValue {
        case "new-message", "message-updated":
            guard let sid = body["sid"]?.stringValue, let session = sessions[sid], let row = body["message"] else { return }
            do {
                let message = try TranscriptMessage(row: row, session: session)
                // One write: every reader of the session list redraws once per message, not twice.
                var updated = session
                updated.seq = max(session.seq, message.seq)
                updated.meaningfulActivityAt = message.createdAt
                sessions[sid] = updated
                guard let transcript = transcripts[sid] else { return }
                if case .after(let seq) = transcript.refresh, message.seq > seq + 1 { await catchUp(sid) }
                applyTranscript([message], to: sid)
                if openSessionIds.contains(sid) { markRead(sid) }
            } catch {
                log.error("message decode failed: \(String(describing: error), privacy: .public)")
            }
        case "update-session":
            guard let id = body["id"]?.stringValue else { return }
            do { try sessions[id]?.apply(update: body) } catch { logBackground(error, "session update") }
            if body["agentState"] != nil, let state = sessions[id]?.agentState, transcripts[id] != nil {
                transcripts[id]?.apply(agentState: state)
            }
        case "pending-changed":
            guard let sid = body["sid"]?.stringValue ?? body["sessionId"]?.stringValue else { return }
            sessions[sid]?.pendingVersion = body["pendingVersion"]?.intValue
            sessions[sid]?.pendingCount = body["pendingCount"]?.intValue ?? 0
            if openSessionIds.contains(sid) { refreshPending(sid) }
        case "new-session":
            if let session = try? Session(row: body, keys: keys) { sessions[session.id] = session }
        case "new-machine":
            await refreshMachines()
        case "update-machine":
            guard let id = body["machineId"]?.stringValue else { return }
            guard let index = machines.firstIndex(where: { $0.id == id }), body["dataEncryptionKey"] == nil else {
                // Unknown, or its key changed: read it again.
                if !machines.isEmpty { await refreshMachines() }
                return
            }
            do { try machines[index].apply(update: body) } catch { logBackground(error, "machine update") }
            if machines[index].revokedAt != nil || machines[index].replacedByMachineId != nil { machines.remove(at: index) }
        case "delete-session":
            if let sid = body["sid"]?.stringValue { forgetDeletedSession(sid) }
        default:
            break
        }
    }

    // MARK: - Transcript

    /// Starts loading a transcript. The load is owned by the store, not by the calling view, so a
    /// view that SwiftUI recreates or dismisses mid-flight cannot leave the transcript half-loaded.
    public func open(_ id: String) {
        openSessionIds.open(id)
        refreshRunnerStatus(id)
        Task { await loadDraft(id) }
        startLoading(id)
    }

    private func startLoading(_ id: String) {
        guard loadTasks[id] == nil else { return }
        loadTasks[id] = Task {
            await load(id)
            loadTasks[id] = nil
        }
    }

    private func load(_ id: String) async {
        guard let session = sessions[id], let api else {
            // Loaded once the session arrives (`didUpdateSessions`).
            log.notice("open: session not known yet")
            return
        }
        if transcripts[id] == nil {
            var transcript = Transcript()
            transcript.apply(agentState: session.agentState)
            transcripts[id] = transcript
        }
        if case .after = transcripts[id]?.refresh {
            await catchUp(id)
        } else {
            loadingTranscripts.insert(id)
            transcriptErrors[id] = nil
            defer { loadingTranscripts.remove(id) }
            do {
                let clock = ContinuousClock()
                let started = clock.now
                let page = try await api.messages(sessionId: id)
                let fetched = clock.now
                await apply(page.rows, to: id)
                log.notice("open: fetch=\(fetched - started, privacy: .public) decode+reduce=\(clock.now - fetched, privacy: .public) rows=\(page.rows.count, privacy: .public)")
                hasOlderMessages[id] = page.hasMore
                transcripts[id]?.markLoaded()
            } catch {
                transcriptErrors[id] = UserFacingError.message(for: error)
                log.error("open failed: \(String(describing: error), privacy: .public)")
            }
        }
        refreshPending(id)
        markRead(id)
    }

    public func close(_ id: String) {
        openSessionIds.close(id)
    }

    public func loadOlder(_ id: String) async {
        guard let api, let minSeq = transcripts[id]?.minSeq, hasOlderMessages[id] == true else { return }
        do {
            let page = try await api.messages(sessionId: id, beforeSeq: minSeq)
            await apply(page.rows, to: id)
            hasOlderMessages[id] = page.hasMore
        } catch { logBackground(error, "older messages") }
    }

    private func catchUp(_ id: String) async {
        guard let api, case .after(var after)? = transcripts[id]?.refresh else { return }
        do {
            while true {
                let page = try await api.messages(sessionId: id, afterSeq: after)
                await apply(page.rows, to: id)
                guard page.hasMore, let next = page.nextAfterSeq, next > after else { break }
                after = next
            }
        } catch { logBackground(error, "transcript catch-up") }
    }

    /// Decrypts and parses rows off the main actor, then applies them in one transcript update.
    private func apply(_ rows: [JSONValue], to id: String) async {
        guard let session = sessions[id] else { return }
        let clock = ContinuousClock()
        let started = clock.now
        let (messages, failures) = await Task.detached(priority: .userInitiated) {
            Self.decode(rows, session: session)
        }.value
        let decoded = clock.now
        if failures > 0 { log.error("\(failures, privacy: .public) messages could not be decoded in a session") }
        applyTranscript(messages, to: id)
        if rows.count > 1 {
            log.notice("apply: decode=\(decoded - started, privacy: .public) reduce=\(clock.now - decoded, privacy: .public) rows=\(rows.count, privacy: .public)")
        }
    }

    /// Applying the canonical transcript also releases any failed local send it confirms. During
    /// an in-flight request, the owner consumes that acknowledgement before finishing its attempt.
    private func applyTranscript(_ messages: [TranscriptMessage], to id: String) {
        transcripts[id]?.apply(messages)
        for message in messages {
            guard let localId = message.localId, let send = outgoingSends[localId],
                  send.sessionId == id, send.acknowledge(message), !send.isSending else { continue }
            outgoingSends[localId] = nil
            failedSends[localId] = nil
        }
    }

    private nonisolated static func decode(_ rows: [JSONValue], session: Session) -> ([TranscriptMessage], Int) {
        var messages: [TranscriptMessage] = []
        var failures = 0
        for row in rows {
            if let message = try? TranscriptMessage(row: row, session: session) { messages.append(message) } else { failures += 1 }
        }
        return (messages, failures)
    }

    private func markRead(_ id: String) {
        guard let api else { return }
        sessions[id]?.unreadSince = nil
        Task { try? await api.setReadState(sessionId: id, read: true) }
    }

    /// Mark as read or unread from the list (swipe or long press).
    public func setRead(_ id: String, _ read: Bool) async {
        guard let api, sessions[id] != nil else { return }
        let previous = sessions[id]?.unreadSince
        sessions[id]?.unreadSince = read ? nil : .now
        do {
            try await api.setReadState(sessionId: id, read: read)
        } catch {
            sessions[id]?.unreadSince = previous
            report(error)
        }
    }

    // MARK: - Actions

    // MARK: - Switching a session's agent

    /// An agent (and model and effort) for a session's next message. A `modelId` of nil or
    /// `"default"` keeps the agent's CLI settings.
    public struct AgentSelection: Equatable, Sendable {
        public let agentId: String
        public let modelId: String?
        public let effort: String?

        public init(agentId: String, modelId: String? = nil, effort: String? = nil) {
            self.agentId = agentId
            self.modelId = modelId
            self.effort = effort
        }
    }

    /// Another agent picked for a session: its next message switches the session to it.
    public var armedAgents: [String: AgentSelection] = [:]

    /// Picking the session's own agent again, with nothing else chosen, cancels the switch.
    public func armAgent(_ selection: AgentSelection?, for sessionId: String) {
        if let selection, selection.agentId == sessions[sessionId]?.agentId,
           selection.modelId == nil || selection.modelId == "default", selection.effort == nil {
            armedAgents[sessionId] = nil
        } else {
            armedAgents[sessionId] = selection
        }
    }

    /// Sends `text` as the first message of another agent in the session: the daemon stops the
    /// current agent and continues the same conversation with the new one (`session.agentTransition`,
    /// what the official app's agent picker does).
    private func switchAgent(_ id: String, to selection: AgentSelection, text: String) async -> Bool {
        guard let session = sessions[id], let machineId = session.machineId, let current = session.agentId else {
            lastError = String(localized: "This session's machine or agent isn't known.")
            return false
        }
        let localId = UUID().uuidString.lowercased()
        if transcripts[id] == nil { transcripts[id] = Transcript() }
        transcripts[id]?.addPending(localId: localId, text: text)
        var meta = controls(for: id)?.messageMeta.objectValue ?? [:]
        meta["source"] = "ui"
        meta["sentFrom"] = .string(sentFrom)
        let params = AgentTransitionRequest.params(sessionId: id, currentAgentId: current, selection: selection,
                                                   text: text, localId: localId, meta: meta)
        let failure: String
        do {
            let result = try await machineRPC(machineId, method: "session.agentTransition", params: params, timeout: .seconds(180))
            switch result["type"]?.stringValue {
            case "accepted":
                armedAgents[id] = nil
                await refreshSessions()
                refreshPending(id)
                return true
            case "rejected":
                failure = String(localized: "The agent couldn't be switched (\(result["code"]?.stringValue ?? "rejected")). The session wasn't changed.")
            case "partially_applied":
                failure = String(localized: "The switch didn't finish (\(result["code"]?.stringValue ?? "partial")). Send again to retry.")
            default:
                failure = String(localized: "It isn't known whether the agent was switched. Check the session before sending again.")
            }
        } catch {
            failure = UserFacingError.message(for: error)
        }
        transcripts[id]?.removePending(localId: localId)
        lastError = failure
        return false
    }

    /// Sends a message as typed in the conversation; false when it couldn't be (the error is reported).
    @discardableResult
    /// `permissionMode` sends the message with that permission intent (a task's) instead of the
    /// composer's, as `session send --permission-mode` does; the session's own mode isn't edited here.
    public func send(_ text: String, attachments: [AttachmentDraft] = [], to id: String, permissionMode: PermissionMode? = nil) async -> Bool {
        guard sessions[id] != nil, let api else {
            log.error("send: unknown session or signed out")
            return false
        }
        if let armed = armedAgents[id] {
            guard attachments.isEmpty else {
                lastError = String(localized: "Send the switch to the new agent as text first; attachments can follow.")
                return false
            }
            return await switchAgent(id, to: armed, text: text)
        }
        let send = OutgoingSend(sessionId: id, text: text, attachments: attachments, permissionMode: permissionMode)
        outgoingSends[send.localId] = send
        if transcripts[id] == nil { transcripts[id] = Transcript() }
        transcripts[id]?.addPending(localId: send.localId, text: text, attachments: attachments.map(\.name))
        return await deliver(send, api: api)
    }

    /// Retries the original message and files, retaining its server deduplication identity.
    @discardableResult
    public func retrySend(_ localId: String, in id: String) async -> Bool {
        guard let api, let send = outgoingSends[localId], send.sessionId == id,
              failedSends[localId] != nil, !send.isSending else { return false }
        send.isCancelled = false
        return await deliver(send, api: api)
    }

    /// Drops a message that failed to send, with its files: it never reached the server (a
    /// delivered one is released by its transcript row instead), so only this device holds it.
    public func discardFailedSend(_ localId: String, in id: String) {
        guard failedSends[localId] != nil, outgoingSends[localId]?.isSending != true else { return }
        outgoingSends[localId]?.isCancelled = true
        outgoingSends[localId] = nil
        failedSends[localId] = nil
        transcripts[id]?.removePending(localId: localId)
    }

    private func deliver(_ send: OutgoingSend, api: HappierAPI) async -> Bool {
        let localId = send.localId
        let id = send.sessionId
        guard let session = sessions[id], !send.isSending else { return false }
        send.isSending = true
        failedSends[localId] = nil
        var succeeded = false
        if !send.attachments.isEmpty {
            uploadProgress[localId] = UploadProgress(totalBytes: send.attachments.reduce(0) { $0 + $1.data.count })
            uploadSessionIds[localId] = id
            uploadObserver?.uploadDidStart(localId: localId, sessionTitle: session.title, fileCount: send.attachments.count)
        }
        defer {
            send.isSending = false
            if uploadProgress.removeValue(forKey: localId) != nil {
                uploadSessionIds[localId] = nil
                uploadObserver?.uploadDidFinish(localId: localId, success: succeeded)
                if inBackground, uploadProgress.isEmpty, !keepsConnectionInBackground { suspendForBackground() }
            }
        }
        do {
            try await unarchiveForDelivery(id, api: api)
            try await send.deliver(context: { [self] in
                guard let session = sessions[id] else { throw CancellationError() }
                var meta = controls(for: id)?.messageMeta.objectValue ?? [:]
                if let mode = send.permissionMode { meta["permissionMode"] = .string(mode.rawValue) }
                meta["source"] = "ui"
                meta["sentFrom"] = .string(sentFrom)
                return (session, meta)
            }, rpc: { [self] method, params in
                // Logout/relay changes cancel the owner before any subsequent network request.
                guard outgoingSends[localId] === send else { throw CancellationError() }
                return try await sessionRPC(id, method: method, params: params)
            }, enqueue: { localId, content, action in
                try await api.enqueueUserMessage(sessionId: id, localId: localId, content: content, action: action)
            }, progress: { [self] bytes in
                uploadProgress[localId]?.add(bytes)
                if let fraction = uploadProgress[localId]?.fraction {
                    uploadObserver?.uploadDidProgress(localId: localId, fraction: fraction)
                }
            })
            guard outgoingSends[localId] === send else { return false }
            succeeded = true
            outgoingSends[localId] = nil
            refreshPending(id)
            return true
        } catch {
            // An account switch must not resurrect old photos or errors in the next account.
            guard outgoingSends[localId] === send else { return false }
            failedSends[localId] = error is CancellationError
                ? String(localized: "Upload interrupted. Your message and photos are saved here. Retry when you're ready.")
                : UserFacingError.message(for: error)
            return false
        }
    }

    // MARK: - Message actions

    public func togglePin(sessionId: String, seq: Int, role: MessagePins.Role) {
        pins.toggle(sessionId: sessionId, seq: seq, role: role)
    }

    /// Rewinds the agent conversation to before this user message and puts its text back in the
    /// composer (`session.rollback`, `TranscriptRollbackActionButton.tsx`).
    public func rollback(_ sessionId: String, toUserMessageSeq seq: Int, restoring text: String) async {
        do {
            _ = try await sessionRPC(sessionId, method: "session.rollback", params: [
                "v": 1, "target": ["type": "before_user_message", "userMessageSeq": .number(Double(seq))],
            ], timeout: .seconds(60))
            if !text.isEmpty { draftSeeds[sessionId] = text }
        } catch { report(error) }
    }

    /// Forks the session up to (and including) this message on its machine (`session.fork` with
    /// `strategy: "auto"`: native fork when the agent supports it, otherwise replay), then opens it.
    public func fork(_ sessionId: String, upToSeq seq: Int, restoring text: String?) async {
        guard let machineId = sessions[sessionId]?.machineId else {
            lastError = String(localized: "This session isn't linked to a machine, so it can't be forked.")
            return
        }
        do {
            let result = try await machineRPC(machineId, method: "session.fork", params: [
                "v": 1, "parentSessionId": .string(sessionId),
                "forkPoint": ["type": "seq", "upToSeqInclusive": .number(Double(seq))], "strategy": "auto",
            ], timeout: .seconds(180))
            guard result["ok"]?.boolValue == true, let childId = result["childSessionId"]?.stringValue else {
                throw RPCError(message: result["errorMessage"]?.stringValue ?? "The fork failed.", code: result["errorCode"]?.stringValue)
            }
            if let text, !text.isEmpty { draftSeeds[childId] = text }
            for _ in 0..<15 where sessions[childId] == nil {
                await refreshSessions()
                if sessions[childId] == nil { try await Task.sleep(for: .seconds(2)) }
            }
            if sessions[childId] != nil { openRequest = childId } else {
                lastError = String(localized: "The fork was created but hasn't appeared yet. It will show up in the list shortly.")
            }
        } catch { report(error) }
    }

    /// Machine-scoped RPC (`apiSocket.ts:410-443`): params/result use the machine's content key.
    /// `authorizingSession` names the session a session-scoped call acts on (stop, runner restart);
    /// the server refuses those without it.
    public func machineRPC(_ machineId: String, method: String, params: JSONValue, timeout: Duration = .seconds(30),
                           authorizingSession: String? = nil) async throws -> JSONValue {
        guard let socket, connection == .online, let api else { throw RPCError(message: "Not connected", code: nil) }
        let machine: Machine
        if let cached = machines.first(where: { $0.id == machineId }) {
            machine = cached
        } else {
            guard let row = try await api.machine(id: machineId) else { throw RPCError(message: "Machine not found", code: nil) }
            machine = try Machine(row: row, keys: keys)
            // Keep it: every machine RPC needs its key, and refetching made quick calls fragile.
            if !machines.contains(where: { $0.id == machineId }) { machines.append(machine) }
        }
        let encoded: JSONValue = try machine.cipher.map { .string(try $0.encryptBase64(params)) } ?? params
        let ack = try await socket.emitWithAck("rpc-call", MachineRPCCall.payload(
            machineId: machineId, method: method, params: encoded, timeoutMs: Int(timeout.components.seconds * 1000),
            authorizingSession: authorizingSession), timeout: timeout + .seconds(5))
        guard let response = ack.first, response["ok"]?.boolValue == true else {
            throw RPCError(message: ack.first?["error"]?.stringValue ?? "The machine didn't respond.", code: ack.first?["errorCode"]?.stringValue)
        }
        var result = response["result"] ?? .null
        if case .array(let items) = result, items.count == 1 { result = items[0] }
        if let cipher = machine.cipher, let ciphertext = result.stringValue { result = try cipher.decryptBase64(ciphertext) }
        return result
    }

    // MARK: - Machines and new sessions

    public func refreshMachines() async {
        guard let api else { return }
        do {
            let rows = try await api.machines()
            machines = Machine.visible(rows.compactMap { try? Machine(row: $0, keys: keys) })
        } catch { report(error) }
        await syncDeviceBrowserRegistrations(loadMachines: false)
    }

    // MARK: - Integrated browser (agents drive it over the relay; see DeviceBrowserRPC)

    /// The app's WebKit browser; nil until the app builds it.
    @ObservationIgnored public weak var deviceBrowserHost: DeviceBrowserHost?
    /// Slots this device serves right now (Settings toggle, platform and browser-open state decide).
    public private(set) var deviceBrowserSlots: Set<DeviceBrowserSlot> = []
    @ObservationIgnored private var registeredBrowserMethods: Set<String> = []

    /// `reclaim` re-registers the served methods even when already registered, so this device
    /// becomes the most recent one on the relay (opening the browser here wins the `focused` slot).
    public func setDeviceBrowserSlots(_ slots: Set<DeviceBrowserSlot>, reclaim: Bool = false) {
        let changed = slots != deviceBrowserSlots
        deviceBrowserSlots = slots
        guard changed || reclaim else { return }
        Task { await syncDeviceBrowserRegistrations(reclaim: reclaim) }
    }

    private func syncDeviceBrowserRegistrations(loadMachines: Bool = true, reclaim: Bool = false) async {
        guard let socket, connection == .online else { return }
        if loadMachines, machines.isEmpty, !deviceBrowserSlots.isEmpty {
            await refreshMachines()
            return
        }
        let desired = Set(DeviceBrowserRPC.methods(machineIds: machines.map(\.id), slots: deviceBrowserSlots))
        let toRegister = reclaim ? desired : desired.subtracting(registeredBrowserMethods)
        let toUnregister = registeredBrowserMethods.subtracting(desired)
        registeredBrowserMethods = desired
        for method in toUnregister.sorted() { try? await socket.emit("rpc-unregister", ["method": .string(method)]) }
        for method in toRegister.sorted() { try? await socket.emit("rpc-register", ["method": .string(method)]) }
    }

    private func answerSocketRequest(_ payload: JSONValue) async -> JSONValue? {
        await DeviceBrowserRPC.reply(to: payload, machines: machines, slots: deviceBrowserSlots, host: deviceBrowserHost)
    }

    // MARK: - Managing machines (`machine/[id]/index.tsx`)

    /// Renames a machine (`displayName`; empty goes back to its host name) by rewriting its whole
    /// metadata over the expected version, retried on top of a newer one (`machineMetadataMerge.ts`).
    public func renameMachine(_ machineId: String, to name: String) async {
        guard let socket, connection == .online else {
            lastError = String(localized: "Not connected. Try again when the connection is back.")
            return
        }
        do {
            for _ in 0..<3 {
                guard let machine = machines.first(where: { $0.id == machineId }) else { return }
                let ack = try await socket.emitWithAck("machine-update-metadata", [
                    "machineId": .string(machineId),
                    "metadata": .string(try machine.encodeMetadata(machine.renamedMetadata(name))),
                    "expectedVersion": .number(Double(machine.metadataVersion)),
                ])
                guard let response = ack.first else { throw RPCError(message: String(localized: "The relay didn't answer."), code: nil) }
                let version = response["version"]?.intValue
                if let version, let index = machines.firstIndex(where: { $0.id == machineId }) {
                    try machines[index].apply(metadata: response["metadata"], version: version)
                }
                switch response["result"]?.stringValue {
                case "success": return
                case "version-mismatch" where version != nil: continue
                default:
                    throw RPCError(message: response["message"]?.stringValue ?? String(localized: "Failed to rename machine."), code: response["result"]?.stringValue)
                }
            }
            throw RPCError(message: String(localized: "The machine changed too often to rename it. Try again."), code: "version-mismatch")
        } catch { report(error) }
    }

    /// Asks the machine's daemon to shut down (`stop-daemon`). Running sessions stay alive, but no
    /// new ones start there until the daemon is started again on that computer.
    public func stopDaemon(_ machineId: String) async -> Bool {
        do {
            _ = try await machineRPC(machineId, method: "stop-daemon", params: [:])
            await refreshMachines()
            return true
        } catch let error as RPCError where RPCErrorCodes.unavailable.contains(error.code ?? "") {
            lastError = String(localized: "Happier can't reach the daemon on this machine. It may be offline, still starting, or disconnected from the relay.")
        } catch { report(error) }
        return false
    }

    /// Removes a machine from the account; it can come back by signing in again from its CLI.
    public func revokeMachine(_ machineId: String) async -> Bool {
        guard let api else { return false }
        do {
            try await api.revokeMachine(id: machineId)
            machines.removeAll { $0.id == machineId }
            return true
        } catch { report(error) }
        return false
    }

    /// The agent CLIs and tmux the machine has (`capabilities.detect`, "machine-details"); nil when
    /// its CLI is too old to say.
    public func detectTools(on machineId: String, refresh: Bool = false) async throws -> DetectedTools? {
        var params: [String: JSONValue] = ["checklistId": "machine-details"]
        if refresh { params["bypassCache"] = true }
        do {
            return DetectedTools(response: try await machineRPC(machineId, method: "capabilities.detect", params: .object(params), timeout: .seconds(20)))
        } catch let error as RPCError where error.code == "RPC_METHOD_NOT_FOUND" {
            return nil
        }
    }

    // MARK: - Machine folders (`daemon.filesystem.*`, `createDirectory`)

    /// Browsable starting points on the machine (home, volumes, or the CLI's allowed roots).
    public func folderRoots(on machineId: String) async throws -> [RemoteFolder] {
        let response = try await machineRPC(machineId, method: "daemon.filesystem.listRoots", params: [:])
        guard response["ok"]?.boolValue == true else {
            throw RemoteFolder.ListingError(message: response["error"]?.stringValue ?? String(localized: "This machine can't list its folders."))
        }
        return (response["roots"]?.arrayValue ?? []).compactMap { root in
            guard let path = root["path"]?.stringValue else { return nil }
            return RemoteFolder(name: root["label"]?.stringValue ?? path, path: path)
        }
    }

    public func folders(in path: String, on machineId: String) async throws -> (folders: [RemoteFolder], truncated: Bool) {
        try RemoteFolder.listing(from: try await machineRPC(machineId, method: "daemon.filesystem.listDirectory",
                                                            params: ["path": .string(path), "includeFiles": false]))
    }

    /// Folders and files in `path`, for picking a file to mention.
    public func entries(in path: String, on machineId: String) async throws -> [RemoteEntry] {
        try RemoteFolder.entries(from: try await machineRPC(machineId, method: "daemon.filesystem.listDirectory",
                                                            params: ["path": .string(path), "includeFiles": true]))
    }

    /// Files under `path` that git doesn't ignore, relative to it, as `rg` prints them.
    private func ripgrepFiles(in path: String, on machineId: String, _ extra: [String] = []) async throws -> String {
        let args = (["--files", "--follow"] + extra).map(JSONValue.string)
        let response = try await machineRPC(machineId, method: "ripgrep", params: [
            "args": .array(args), "cwd": .string(path),
        ], timeout: .seconds(30))
        guard response["success"]?.boolValue == true, let stdout = response["stdout"]?.stringValue else {
            throw RemoteFolder.ListingError(message: response["error"]?.stringValue ?? String(localized: "This folder's files can't be listed."))
        }
        return stdout
    }

    /// Files and folders of a project folder to mention with `@`, best match first, as the official
    /// composer finds them (`suggestionFile.ts`): from the folder's index, or by name on the machine
    /// when the index has no match (a file added since, or a folder too big to list whole).
    public func fileSuggestions(in path: String, on machineId: String, query: String, limit: Int) async throws -> [String] {
        var index: [String] = []
        var indexError: Error?
        do { index = try await fileIndex(in: path, on: machineId) } catch { indexError = error }
        let hits = FileMention.search(index, query: query, limit: limit)
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hits.isEmpty, !typed.isEmpty else {
            if let indexError, typed.isEmpty { throw indexError }
            return hits
        }
        do {
            let found = try await ripgrepFiles(in: path, on: machineId, ["--hidden", "--iglob", FileMention.nameGlob(typed)])
            return FileMention.search(FileMention.index(fromRipgrep: found), query: query, limit: limit)
        } catch {
            throw indexError ?? error
        }
    }

    /// A folder's `@` index, listed once and reused for a few minutes. Every caller shares the one
    /// listing in flight, and a caller that goes away (the `@` typed and deleted) doesn't cancel it;
    /// a failed listing isn't kept, so the next keystroke tries again.
    private func fileIndex(in path: String, on machineId: String) async throws -> [String] {
        let key = "\(machineId)|\(path)"
        if let hit = fileIndexes[key], Date.now.timeIntervalSince(hit.listedAt) < 300 { return hit.entries }
        let listing = fileIndexListings[key] ?? Task {
            FileMention.index(fromRipgrep: try await ripgrepFiles(in: path, on: machineId))
        }
        fileIndexListings[key] = listing
        do {
            let entries = try await listing.value
            fileIndexes[key] = (entries, .now)
            fileIndexListings[key] = nil
            return entries
        } catch {
            fileIndexListings[key] = nil
            log.error("file index: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    @ObservationIgnored private var fileIndexes: [String: (entries: [String], listedAt: Date)] = [:]
    @ObservationIgnored private var fileIndexListings: [String: Task<[String], Error>] = [:]

    /// Creates `name` inside `parent`; the daemon's filesystem access policy decides what's allowed.
    public func createFolder(named name: String, in parent: String, on machineId: String) async throws -> RemoteFolder {
        let platform = machines.first { $0.id == machineId }?.platform
        let path = RemoteFolder.join(parent, name, platform: platform)
        let response = try await machineRPC(machineId, method: "createDirectory", params: ["path": .string(path)])
        guard response["success"]?.boolValue == true else {
            throw RemoteFolder.ListingError(message: response["error"]?.stringValue ?? String(localized: "The folder couldn't be created."))
        }
        return RemoteFolder(name: name, path: path)
    }

    /// The agents a machine has installed (its daemon's `new-session` checklist), asked once and
    /// reused for a few minutes; nil when the machine can't tell.
    public func installedAgents(on machineId: String) async -> Set<String>? {
        if let hit = installedAgentsByMachine[machineId], Date.now.timeIntervalSince(hit.at) < 300 { return hit.agents }
        do {
            let response = try await machineRPC(machineId, method: "capabilities.detect", params: ["checklistId": "new-session"],
                                                timeout: .seconds(15))
            guard let agents = Agent.installed(fromDetect: response) else { return nil }
            installedAgentsByMachine[machineId] = (agents, .now)
            return agents
        } catch {
            log.error("installed agents: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    @ObservationIgnored private var installedAgentsByMachine: [String: (agents: Set<String>, at: Date)] = [:]

    public enum SpawnOutcome: Equatable, Sendable {
        case created(sessionId: String)
        /// The folder doesn't exist; ask, then retry with `approveNewDirectory: true`.
        case needsDirectoryApproval(String)
        case failed(String)
    }

    /// Starts an agent in a folder on a machine (`spawn-happy-session`, `spawnSessionPayload.ts`),
    /// waits for the session to appear, sends the first message and opens it.
    public func createSession(machineId: String, directory: String, agentId: String, permissionMode: PermissionMode,
                              modelId: String? = nil, effort: String? = nil, agent: AgentProfile? = nil,
                              firstMessage: String, attachments: [AttachmentDraft] = [], goal: String? = nil,
                              approveNewDirectory: Bool = false,
                              grouping: NewSessionGroup? = nil, title: String? = nil) async -> SpawnOutcome {
        let nonce = UUID().uuidString.lowercased()
        let params = SpawnRequest.params(directory: directory, agentId: agentId, permissionMode: permissionMode, modelId: modelId,
                                         effort: effort, nonce: nonce, approveNewDirectory: approveNewDirectory, agent: agent)
        do {
            var result: JSONValue
            do {
                result = try await machineRPC(machineId, method: "spawn-happy-session.provider-safe.v1", params: params, timeout: .seconds(300))
            } catch let error as RPCError where ["RPC_METHOD_NOT_AVAILABLE", "RPC_METHOD_NOT_FOUND"].contains(error.code ?? "") {
                result = try await machineRPC(machineId, method: "spawn-happy-session", params: params, timeout: .seconds(300))
            }
            switch result["type"]?.stringValue {
            case "requestToApproveDirectoryCreation":
                return .needsDirectoryApproval(result["directory"]?.stringValue ?? directory)
            case "error":
                return .failed(result["errorMessage"]?.stringValue ?? String(localized: "The machine couldn't start the session."))
            default:
                break
            }
            var sessionId = result["sessionId"]?.stringValue
            for _ in 0..<30 where sessionId == nil {
                try await Task.sleep(for: .seconds(2))
                let resolved = try await machineRPC(machineId, method: "daemon.spawnSession.resolve", params: ["spawnNonce": .string(nonce)])
                switch resolved["status"]?.stringValue {
                case "success": sessionId = resolved["sessionId"]?.stringValue
                case "error": return .failed(resolved["errorMessage"]?.stringValue ?? String(localized: "The session failed to start."))
                case "not_found", "unsupported": return .failed(String(localized: "The machine lost track of the new session."))
                default: continue
                }
            }
            guard let sessionId else { return .failed(String(localized: "The session is taking too long to start. It will appear in the list when ready.")) }
            for _ in 0..<15 where sessions[sessionId] == nil {
                await refreshSessions()
                if sessions[sessionId] == nil { try await Task.sleep(for: .seconds(1)) }
            }
            if let grouping {
                await group(grouping, under: sessionId, title: title ?? grouping.suggestedTitle)
            }
            let message = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            // A goal chosen before starting is set first, so the first turn already pursues it.
            if let goal = goal?.trimmingCharacters(in: .whitespacesAndNewlines), !goal.isEmpty, sessions[sessionId] != nil {
                await setGoal(sessionId, objective: goal)
            }
            // The first message's files upload to the new session's machine like any later message's.
            if !message.isEmpty || !attachments.isEmpty, sessions[sessionId] != nil {
                await send(message, attachments: attachments, to: sessionId)
            }
            openRequest = sessionId
            return .created(sessionId: sessionId)
        } catch {
            return .failed(UserFacingError.message(for: error))
        }
    }

    // MARK: - Pending queue

    /// Refetches the queue; concurrent requests collapse into one follow-up fetch.
    public func refreshPending(_ id: String) {
        guard pendingFetches[id] == nil else {
            pendingFetchDirty.insert(id)
            return
        }
        pendingFetches[id] = Task {
            repeat {
                pendingFetchDirty.remove(id)
                guard let api, let session = sessions[id] else { break }
                do {
                    let rows = try await api.pending(sessionId: id)
                    let items = await Task.detached { PendingMessage.list(rows, session: session) }.value
                    pendingQueues[id] = items
                } catch {
                    log.error("pending refresh failed: \(String(describing: error), privacy: .public)")
                }
            } while pendingFetchDirty.contains(id)
            pendingFetches[id] = nil
        }
    }

    public func steerPendingNow(_ localId: String, in id: String) async {
        await pendingMutation(id, localId) { api in
            try await self.unarchiveForDelivery(id, api: api)
            try await api.setPendingAction(sessionId: id, localId: localId, action: .steerNow)
        }
    }

    /// Stops the current turn and sends this message (server `interrupt_and_send` while busy).
    public func sendPendingNow(_ localId: String, in id: String) async {
        await pendingMutation(id, localId) { api in
            try await self.unarchiveForDelivery(id, api: api)
            try await api.setPendingAction(sessionId: id, localId: localId, action: .sendNow)
        }
    }

    /// Puts a blocked or discarded message back in line.
    public func requeuePending(_ localId: String, in id: String) async {
        let discarded = pendingQueues[id]?.first { $0.localId == localId }?.state == .discarded
        await pendingMutation(id, localId) { api in
            try await self.unarchiveForDelivery(id, api: api)
            if discarded {
                try await api.restorePending(sessionId: id, localId: localId)
            } else {
                try await api.setPendingAction(sessionId: id, localId: localId, action: .enqueue)
            }
        }
    }

    /// Discarded rows must be restored before their action can change (`pendingMessageService` rejects them).
    public func restoreAndSend(_ localId: String, action: PendingAction, in id: String) async {
        await pendingMutation(id, localId) { api in
            try await self.unarchiveForDelivery(id, api: api)
            try await api.restorePending(sessionId: id, localId: localId)
            try await api.setPendingAction(sessionId: id, localId: localId, action: action)
        }
    }

    public func removePending(_ localId: String, in id: String) async {
        await pendingMutation(id, localId) { api in
            try await api.removePending(sessionId: id, localId: localId)
        }
    }

    public func editPending(_ localId: String, text: String, in id: String) async {
        guard let session = sessions[id], let record = pendingQueues[id]?.first(where: { $0.localId == localId })?.record else {
            lastError = String(localized: "This message can't be edited.")
            return
        }
        let edited = PendingMessage.editedRecord(record, text: text)
        await pendingMutation(id, localId) { api in
            let content: JSONValue = session.isPlain ? ["t": "plain", "v": edited] : .string(try session.encodeDocument(edited))
            try await api.editPending(sessionId: id, localId: localId, content: content)
        }
    }

    /// Sending to an archived conversation resumes it. The daemon won't start an archived session
    /// for a queued message (`activatePendingInactiveSession.ts` rejects it as ineligible, and the
    /// message just sits there), so it leaves the archive first, like the official Resume
    /// (`runResumeSession`).
    private func unarchiveForDelivery(_ id: String, api: HappierAPI) async throws {
        guard sessions[id]?.archivedAt != nil else { return }
        try await api.unarchive(sessionId: id)
        sessions[id]?.archivedAt = nil
        openedArchivedIds.remove(id)
    }

    private func pendingMutation(_ id: String, _ localId: String, _ work: (HappierAPI) async throws -> Void) async {
        guard let api else { return }
        do { try await work(api) } catch let error as HTTPClient.ServerError where error.status == 409 || error.status == 404 {
            lastError = String(localized: "This pending message changed while the action was being applied. The list was refreshed.")
        } catch { report(error) }
        refreshPending(id)
    }

    /// Default `attachmentsUploadsMaxFileBytes` of the official client (25 MiB).
    /// Matches the daemon's `HAPPIER_FILES_UPLOAD_MAX_FILE_BYTES` on the machines this app talks to
    /// (raised from its 50 MB default to 500 MB on the Mac mini's service).
    public nonisolated static let maxAttachmentBytes = 500 * 1024 * 1024

    /// Splits picked or dropped files into ones that can be uploaded and the names of those over the limit.
    public nonisolated static func screenAttachments(_ drafts: [AttachmentDraft]) -> (accepted: [AttachmentDraft], tooLarge: [String]) {
        (drafts.filter { $0.data.count <= maxAttachmentBytes }, drafts.filter { $0.data.count > maxAttachmentBytes }.map(\.name))
    }

    // MARK: - Attachments from the machine

    /// An attached file, downloaded from the session's machine once (`daemon.bulkTransfer.download.*`,
    /// as the official client's file previews) and kept in Caches for later opens.
    /// `refresh` fetches mutable linked files again; a failed refresh never returns stale bytes.
    public func attachmentFile(_ file: MessageAttachment, in sessionId: String, refresh: Bool = false,
                               progress: @escaping @MainActor (Double) -> Void = { _ in }) async throws -> URL {
        guard let path = file.path else { throw RPCError(message: "This attachment has no file on the computer.", code: nil) }
        let url = Self.attachmentCacheURL(for: file, sessionId: sessionId)
        if !refresh, FileManager.default.fileExists(atPath: url.path) { return url }
        if let running = attachmentDownloads[url] { return try await running.value }
        let task = Task { () throws -> URL in
            try await download(path: path, sessionId: sessionId, to: url, progress: progress)
            return url
        }
        attachmentDownloads[url] = task
        defer { attachmentDownloads[url] = nil }
        return try await task.value
    }

    @ObservationIgnored private var attachmentDownloads: [URL: Task<URL, Error>] = [:]

    /// The attachment's preview: the one the sender included, else (images up to 16 MB, as the
    /// official client) made from the downloaded file and kept on disk. Nil for files to open first.
    public func attachmentThumbnail(_ file: MessageAttachment, in sessionId: String) async -> AttachmentThumbnail? {
        if let thumbnail = file.thumbnail { return thumbnail }
        guard file.isImage, (file.sizeBytes ?? 0) <= 16 * 1024 * 1024 else { return nil }
        let cached = Self.attachmentCacheURL(for: file, sessionId: sessionId).appendingPathExtension("thumb.jpg")
        if let data = try? Data(contentsOf: cached) { return await AttachmentThumbnail.make(data: data, mimeType: "image/jpeg") }
        do {
            let url = try await attachmentFile(file, in: sessionId)
            guard let thumbnail = await AttachmentThumbnail.make(fileURL: url, mimeType: file.mimeType) else { return nil }
            try? thumbnail.jpeg.write(to: cached)
            return thumbnail
        } catch {
            log.error("attachment preview: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Where a downloaded attachment is kept: by content hash when known, else by session and path.
    static func attachmentCacheURL(for file: MessageAttachment, sessionId: String) -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Happier/Downloads")
        let key = file.sha256 ?? Data(SHA256.hash(data: Data("\(sessionId)|\(file.path ?? file.name)".utf8))).map { String(format: "%02x", $0) }.joined()
        let folder = directory.appending(path: String(key.prefix(32)))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: file.name)
    }

    /// Relative paths use the session folder; absolute paths keep the remote machine's syntax.
    static func attachmentPathForMachine(_ path: String, sessionPath: String?) -> String {
        RemoteFileLink.isAbsolutePath(path) ? path : ((sessionPath ?? "") as NSString).appendingPathComponent(path)
    }

    /// The chunked, encrypted download of one file into `destination`. Tries the session's own
    /// route, then the machine's (for a session not running), with the path from its folder.
    private func download(path: String, sessionId: String, to destination: URL, progress: @escaping @MainActor (Double) -> Void) async throws {
        let recipient = try TransferRecipient()
        let request: JSONValue = ["t": "session_file_download_v1", "path": .string(path), "asZip": false,
                                  "recipientPublicKeyBase64": .string(recipient.publicKeyBase64)]
        let call: (String, JSONValue) async throws -> JSONValue
        let initResponse: JSONValue
        if let response = try? await sessionRPC(sessionId, method: "daemon.bulkTransfer.download.init", params: request),
           response["success"]?.boolValue == true {
            call = { [unowned self] method, params in try await sessionRPC(sessionId, method: method, params: params) }
            initResponse = response
        } else {
            guard let session = sessions[sessionId], let machineId = session.machineId else {
                throw RPCError(message: "The computer for this session isn't known.", code: nil)
            }
            let absolute = Self.attachmentPathForMachine(path, sessionPath: session.path)
            var machineRequest = request
            if case .object(var object) = machineRequest { object["path"] = .string(absolute); machineRequest = .object(object) }
            call = { [unowned self] method, params in try await machineRPC(machineId, method: method, params: params) }
            initResponse = try await call("daemon.bulkTransfer.download.init", machineRequest)
        }
        guard initResponse["success"]?.boolValue == true, let downloadId = initResponse["downloadId"]?.stringValue else {
            throw RPCError(message: initResponse["error"]?.stringValue ?? "The computer couldn't send the file.", code: nil)
        }
        let total = max(initResponse["sizeBytes"]?.intValue ?? 0, 1)
        let partial = destination.appendingPathExtension("part")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        do {
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }
            var index = 0
            var received = 0
            while true {
                let chunk = try await call("daemon.bulkTransfer.download.chunk", ["downloadId": .string(downloadId), "index": .number(Double(index))])
                guard chunk["success"]?.boolValue != false else {
                    throw RPCError(message: chunk["error"]?.stringValue ?? "The download stopped.", code: nil)
                }
                let bytes: Data
                if let payload = chunk["payloadBase64"]?.stringValue, let envelope = chunk["encryptedDataKeyEnvelopeBase64"]?.stringValue {
                    bytes = try TransferChunk.decrypt(payloadBase64: payload, encryptedDataKeyEnvelopeBase64: envelope,
                                                      transferId: downloadId, index: index, recipient: recipient)
                } else if let plain = chunk["contentBase64"]?.stringValue, let data = Data(base64Encoded: plain) {
                    bytes = data
                } else {
                    throw RPCError(message: "The computer sent an unreadable part of the file.", code: nil)
                }
                try handle.write(contentsOf: bytes)
                received += bytes.count
                progress(min(Double(received) / Double(total), 1))
                if chunk["isLast"]?.boolValue == true { break }
                index += 1
            }
            _ = try? await call("daemon.bulkTransfer.download.finalize", ["downloadId": .string(downloadId)])
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            _ = try? await call("daemon.bulkTransfer.download.abort", ["downloadId": .string(downloadId)])
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    public func reply(_ reply: PermissionReply, to request: (id: String, tool: String), in sessionId: String) async {
        do { try await sendPermissionReply(reply, to: request, in: sessionId) } catch { report(error) }
    }

    /// The one way a permission is answered, from the conversation or from a notification.
    private func sendPermissionReply(_ reply: PermissionReply, to request: (id: String, tool: String), in sessionId: String) async throws {
        let agentId = sessions[sessionId]?.agentId
        _ = try await sessionRPC(sessionId, method: "permission", params: reply.payload(requestId: request.id, tool: request.tool, agentId: agentId))
        if reply.abortsTurn(agentId: agentId) { await abort(sessionId) }
    }

    /// Answers an AskUserQuestion-style request (`structuredQuestionAnswersV1.ts`).
    public func answer(_ answers: [String: [String]], to requestId: String, in sessionId: String) async {
        let structured = sessions[sessionId]?.agentState["capabilities"]?["structuredQuestionAnswersV1Supported"]?.boolValue == true
        do {
            if structured {
                let payload = JSONValue.object(answers.mapValues { .array($0.map(JSONValue.string)) })
                _ = try await sessionRPC(sessionId, method: "session.structuredQuestion.respond.v1",
                                         params: ["id": .string(requestId), "structuredAnswersV1": payload])
            } else {
                let payload = JSONValue.object(answers.mapValues { .string($0.joined(separator: ", ")) })
                _ = try await sessionRPC(sessionId, method: "permission",
                                         params: ["id": .string(requestId), "approved": true, "answers": payload])
            }
        } catch { report(error) }
    }

    /// Reconnect the existing conversation without inserting a user message or changing its agent.
    @discardableResult
    public func resumeSession(_ sessionId: String) async -> Bool {
        guard let session = sessions[sessionId], session.status() == .offline,
              session.archivedAt == nil, resumingSessions[sessionId] != true else { return false }
        resumingSessions[sessionId] = true
        defer { resumingSessions[sessionId] = nil }
        do {
            let request = try SessionResumeRequest(session: session, requestId: UUID().uuidString.lowercased())
            // This existing RPC waits for the accepted session id, including on older daemons.
            // Resume uses the same startup budget as creating a session.
            let response = try await machineRPC(request.machineId, method: "spawn-happy-session",
                                                params: request.params, timeout: .seconds(300))
            try SessionResumeRequest.validate(response, sessionId: sessionId)
            await refreshSessions()
            return true
        } catch {
            report(error)
            return false
        }
    }

    public func abort(_ sessionId: String) async {
        do {
            _ = try await sessionRPC(sessionId, method: "abort", params: [
                "reason": "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed.",
            ])
        } catch let error as RPCError where error.code == "RPC_METHOD_NOT_AVAILABLE" {
            // Session runtime is offline: nothing to abort.
        } catch { report(error) }
    }

    /// Sets the session's goal or moves it along (`session.goal.set`): a new objective, or a
    /// status (paused, active, complete). The runtime publishes the result in the session's work
    /// state, which updates the composer's goal chip.
    public func setGoal(_ sessionId: String, objective: String? = nil, status: SessionGoal.Status? = nil) async {
        var params: [String: JSONValue] = [:]
        if let objective { params["objective"] = .string(objective) }
        if let status { params["status"] = .string(status.rawValue) }
        await goalRPC(sessionId, method: "session.goal.set", params: .object(params))
    }

    public func clearGoal(_ sessionId: String) async {
        await goalRPC(sessionId, method: "session.goal.clear", params: [:])
    }

    private func goalRPC(_ sessionId: String, method: String, params: JSONValue) async {
        do {
            let response = try await sessionRPC(sessionId, method: method, params: params)
            if response["ok"]?.boolValue != true {
                lastError = response["error"]?.stringValue ?? String(localized: "The agent couldn't update the goal.")
            }
        } catch { report(error) }
    }

    /// A stop the user has to confirm, optionally followed by archiving.
    public struct StopRequest: Identifiable, Equatable, Sendable {
        public let sessionId: String
        public let thenArchive: Bool
        public var id: String { sessionId }
    }

    // MARK: - Pinned conversations

    /// Pinned session ids in pin order (shared with the official app through the account).
    public private(set) var pinnedSessionIds: [String] = []

    private func refreshPinnedSessions() async {
        guard let api else { return }
        do {
            pinnedSessionIds = SessionPins.orderedIds(fromSnapshot: try await api.sessionOrganizationPins())
        } catch {
            logBackground(error, "pinned sessions")
        }
    }

    public func isPinned(_ sessionId: String) -> Bool { pinnedSessionIds.contains(sessionId) }

    /// Pins or unpins right away; reverts if the server refuses.
    public func setPinned(_ sessionId: String, _ pinned: Bool) async {
        guard let api, isPinned(sessionId) != pinned else { return }
        let previous = pinnedSessionIds
        if pinned { pinnedSessionIds.append(sessionId) } else { pinnedSessionIds.removeAll { $0 == sessionId } }
        do {
            try await api.setSessionPin(sessionId, pinned: pinned)
        } catch {
            pinnedSessionIds = previous
            report(error)
        }
    }

    // MARK: - Runner on an older CLI

    /// Runner restarts in flight, and the runner pid each restart replaces (hidden once replaced).
    public private(set) var restartingRunners: Set<String> = []
    /// Attachment upload progress per message being sent (keyed by the message's localId).
    public private(set) var uploadProgress: [String: UploadProgress] = [:]
    /// The session each in-flight upload belongs to.
    private var uploadSessionIds: [String: String] = [:]
    /// Failed local messages remain in the transcript with their original files until retried.
    public private(set) var failedSends: [String: String] = [:]
    @ObservationIgnored private var outgoingSends: [String: OutgoingSend] = [:]
    /// Platform hook for keeping uploads alive in the background (iOS continued-processing tasks).
    @ObservationIgnored public weak var uploadObserver: (any UploadObserver)?

    /// Combined progress of a session's in-flight uploads, for the session list.
    public func uploadFraction(inSession sessionId: String) -> Double? {
        let uploads = uploadSessionIds.filter { $0.value == sessionId }.compactMap { uploadProgress[$0.key] }
        guard !uploads.isEmpty else { return nil }
        return UploadProgress.combinedFraction(uploads)
    }

    /// Stops an upload before its next chunk (the system's background-task UI was cancelled).
    public func cancelUpload(_ localId: String) {
        guard uploadProgress[localId] != nil else { return }
        outgoingSends[localId]?.isCancelled = true
    }
    /// The daemon's runner status per open session (`daemon.sessionRunner.status.get`).
    private var runnerStates: [String: JSONValue] = [:]
    @ObservationIgnored private var runnerStatusTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var replacedRunnerPids: [String: Int] = [:]

    /// The "older CLI" notice for a session, unless that runner is already being replaced.
    public func staleRunner(for sessionId: String) -> StaleRunner? {
        guard let session = sessions[sessionId], let state = runnerStates[sessionId],
              let stale = SessionRunner.staleRunner(sessionId: sessionId, machineId: session.machineId, state: state),
              replacedRunnerPids[sessionId] != stale.expectedRunnerPid
        else { return nil }
        return stale
    }

    /// Asks the session's daemon which CLI its runner is on: when the session opens, when the socket
    /// reconnects and when a turn ends (restart eligibility changes between turns). The request is
    /// owned by the store so a view that SwiftUI recreates or dismisses cannot cancel it; without a
    /// connection it is skipped and the reconnect asks again.
    private func refreshRunnerStatus(_ sessionId: String) {
        guard connection == .online, runnerStatusTasks[sessionId] == nil else { return }
        runnerStatusTasks[sessionId] = Task {
            await fetchRunnerStatus(sessionId)
            runnerStatusTasks[sessionId] = nil
        }
    }

    private func fetchRunnerStatus(_ sessionId: String) async {
        guard let machineId = sessions[sessionId]?.machineId else { return }
        do {
            runnerStates[sessionId] = try await machineRPC(machineId, method: SessionRunner.statusMethod,
                                                           params: ["sessionId": .string(sessionId)])
        } catch {
            // Older daemons don't expose the status; there is simply no notice.
            logBackground(error, "runner status")
        }
    }

    /// Restarts the session's runner on the daemon's current CLI; the conversation is kept.
    public func restartStaleRunner(_ sessionId: String) async {
        guard let stale = staleRunner(for: sessionId), !restartingRunners.contains(sessionId) else { return }
        restartingRunners.insert(sessionId)
        defer { restartingRunners.remove(sessionId) }
        do {
            let result = try await machineRPC(stale.machineId, method: SessionRunner.restartMethod,
                                              params: SessionRunner.restartRequest(stale), timeout: .seconds(90),
                                              authorizingSession: sessionId)
            switch SessionRunner.outcome(result) {
            case .restarted:
                replacedRunnerPids[sessionId] = stale.expectedRunnerPid
                await fetchRunnerStatus(sessionId)
            case .busy:
                lastError = String(localized: "The session is busy. Update it when the current turn finishes.")
            case .failed:
                lastError = String(localized: "Happier couldn't restart this session on the new CLI. The session is still available.")
            }
        } catch { report(error) }
    }

    /// Set when a stop needs confirmation; the UI asks and calls `confirmStop`.
    public var stopRequest: StopRequest?

    /// Archives an idle session; a running one is stopped first, after confirmation
    /// (`executeArchiveAction` in `sessionActionExecution.ts`).
    public func archive(_ sessionId: String) async {
        guard let api else { return }
        if sessions[sessionId]?.active == true {
            stopRequest = StopRequest(sessionId: sessionId, thenArchive: true)
            return
        }
        do {
            try await api.archive(sessionId: sessionId)
            sessions[sessionId]?.archivedAt = .now
        } catch let error as HTTPClient.ServerError where error.status == 409 {
            // The server can know the session is active before this client does.
            stopRequest = StopRequest(sessionId: sessionId, thenArchive: true)
        } catch { report(error) }
    }

    // MARK: - Deleting a session for good

    /// A delete the user has to confirm (`ui.session.delete`); the UI asks and calls `confirmDelete`.
    /// It holds the session itself: archived ones, browsed page by page, aren't in `sessions`.
    public var deleteRequest: Session?
    /// Sessions deleted from this device, for lists that hold their own copies (the archive).
    public private(set) var deletedSessionIds: Set<String> = []

    public func requestDelete(_ session: Session) {
        guard session.canDelete else { return }
        deleteRequest = session
    }

    /// `DELETE /v1/sessions/:id`: the relay removes the session with its messages and tells every
    /// device (`delete-session`). It is dropped here at once rather than when that update arrives.
    public func confirmDelete(_ session: Session) async {
        guard let api, session.canDelete else { return }
        do {
            try await api.delete(sessionId: session.id)
            forgetDeletedSession(session.id)
        } catch let error as HTTPClient.ServerError where error.status == 404 {
            // Already gone.
            forgetDeletedSession(session.id)
        } catch { report(error) }
    }

    private func forgetDeletedSession(_ sessionId: String) {
        deletedSessionIds.insert(sessionId)
        sessions[sessionId] = nil
        transcripts[sessionId] = nil
        pendingQueues[sessionId] = nil
        pinnedSessionIds.removeAll { $0 == sessionId }
    }

    // MARK: - Renaming and nesting sessions by hand

    /// Renames a session (its `summary`, as the official app's rename and the agent's own title
    /// updates write it).
    public func rename(_ sessionId: String, to title: String) async {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        await editMetadata(sessionId) { MetadataEdit.setTitle(name, in: $0, now: $1) }
    }

    /// Whether other sessions are nested under this one in the list.
    public func hasNestedSessions(_ sessionId: String) -> Bool {
        sessions.values.contains { $0.parentSessionId == sessionId && $0.isUserFacing }
    }

    /// Whether `sessionId` can go under `parentId` (not under itself or one of its own sessions).
    public func canNest(_ sessionId: String, under parentId: String) -> Bool {
        SessionTree.canNest(sessionId, under: parentId) { self.sessions[$0]?.parentSessionId }
    }

    /// Moves a session under another one in the list, or to the top level (nil). Only the list's
    /// nesting changes; the sessions keep their folders and conversations.
    public func nest(_ sessionId: String, under parentId: String?) async {
        if let parentId, !canNest(sessionId, under: parentId) { return }
        await editMetadata(sessionId) { MetadataEdit.setListParent(parentId, in: $0, now: $1) }
    }

    /// The normal creation path has successfully started the parent. Keep the target's place in
    /// the tree; no nesting is attempted before the new session exists.
    private func group(_ group: NewSessionGroup, under parentId: String, title: String) async {
        guard sessions[parentId] != nil, let targetSession = sessions[group.targetId], sessions[group.draggedId] != nil else {
            lastError = String(localized: "The new session started, but the sessions to group couldn't be loaded.")
            return
        }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        await editMetadata(parentId) { MetadataEdit.setTitle(name.isEmpty ? group.suggestedTitle : name, in: $0, now: $1) }
        if let grandparent = targetSession.parentSessionId { await nest(parentId, under: grandparent) }
        await nest(group.targetId, under: parentId)
        await nest(group.draggedId, under: parentId)
    }

    /// Whether a session was archived or deleted. One the list doesn't hold is asked for, so a
    /// session too new to be listed yet isn't taken for a gone one; false when it can't be told.
    public func isArchivedOrDeleted(_ sessionId: String) async -> Bool {
        if let session = sessions[sessionId] { return session.archivedAt != nil }
        guard hasLoadedSessions, let api else { return false }
        do {
            guard let row = try await api.session(id: sessionId) else { return true }
            return (try? Session(row: row, keys: keys))?.archivedAt != nil
        } catch let error as HTTPClient.ServerError where error.status == 404 {
            return true
        } catch {
            return false
        }
    }

    /// One page of archived sessions, decrypted but not added to the list: the archive is browsed
    /// (or searched) on demand and let go afterwards.
    public func archivedSessions(cursor: String?, limit: Int = 50) async throws -> (sessions: [Session], nextCursor: String?) {
        guard let api else { return ([], nil) }
        let page = try await api.archivedSessions(cursor: cursor, limit: limit)
        let keys = self.keys
        return (page.rows.compactMap { try? Session(row: $0, keys: keys) }, page.nextCursor)
    }

    /// Opens a session referenced by an inter-session message or automatic activity notice.
    public func openRelatedSession(_ id: String) async {
        if sessions[id] != nil {
            openRequest = id
            return
        }
        guard let api, let account = snapshots else {
            lastError = String(localized: "Connect to load this session.")
            return
        }
        do {
            let row = try await api.session(id: id)
            guard !Task.isCancelled, snapshots === account else { return }
            guard let row, row != .null else {
                lastError = String(localized: "This session is no longer available.")
                return
            }
            openArchived(try Session(row: row, keys: keys))
        } catch let error as HTTPClient.ServerError where error.status == 404 {
            guard !Task.isCancelled, snapshots === account else { return }
            lastError = String(localized: "This session is no longer available.")
        } catch {
            guard !Task.isCancelled, snapshots === account else { return }
            report(error)
        }
    }

    /// Opens an archived conversation found in the archive or a search.
    public func openArchived(_ session: Session) {
        openedArchivedIds.insert(session.id)
        if sessions[session.id] == nil { sessions[session.id] = session }
        openRequest = session.id
    }

    public func unarchive(_ sessionId: String) async {
        guard let api else { return }
        do {
            try await api.unarchive(sessionId: sessionId)
            sessions[sessionId]?.archivedAt = nil
            openedArchivedIds.remove(sessionId)
            await refreshSessions()
        } catch { report(error) }
    }

    // MARK: - Synced drafts

    /// The draft text as last synced, by session: what this or another device saved. The composer
    /// takes it up when you haven't typed over it.
    public let syncedDrafts = KeyedStore<SyncedDraft>()

    public struct SyncedDraft: Equatable, Sendable {
        public let text: String
        public let revision: Int?
    }

    /// Per-session sync bookkeeping: the revision and document the next write builds on, the text
    /// waiting to go up, and the debounce.
    private struct DraftState {
        var revision: Int?
        var document: JSONValue?
        var syncedText = ""
        var pending: String?
        var upload: Task<Void, Never>?
    }

    @ObservationIgnored private var draftStates: [String: DraftState] = [:]
    /// Where text not yet synced is kept on this device, so a closed app loses nothing.
    @ObservationIgnored private var pendingDraftsKey: String?

    private func restorePendingDrafts() {
        guard let key = pendingDraftsKey, let saved = UserDefaults.standard.dictionary(forKey: key) as? [String: String] else { return }
        for (sessionId, text) in saved {
            var state = draftStates[sessionId] ?? DraftState()
            state.pending = text
            draftStates[sessionId] = state
        }
    }

    private func savePendingDrafts() {
        guard let key = pendingDraftsKey else { return }
        let pending = draftStates.compactMapValues(\.pending)
        if pending.isEmpty { UserDefaults.standard.removeObject(forKey: key) } else { UserDefaults.standard.set(pending, forKey: key) }
    }

    /// The latest text typed for a session on this device, synced or not.
    public func localDraft(_ sessionId: String) -> String? {
        guard let state = draftStates[sessionId] else { return nil }
        return state.pending ?? state.syncedText
    }

    /// The composer changed: the draft goes up 2 seconds after typing stops (`useDraft.ts`), at
    /// once when it becomes empty or stops being empty.
    public func draftChanged(_ sessionId: String, text: String) {
        var state = draftStates[sessionId] ?? DraftState()
        guard text != (state.pending ?? state.syncedText) else { return }
        let emptiness = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            != state.syncedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        state.pending = text
        draftStates[sessionId] = state
        savePendingDrafts()
        state.upload?.cancel()
        state.upload = Task { [weak self] in
            if !emptiness { try? await Task.sleep(for: .seconds(2)) }
            guard !Task.isCancelled else { return }
            await self?.uploadDraft(sessionId)
        }
        draftStates[sessionId] = state
    }

    /// Sends every waiting draft now (the app is going to the background).
    public func flushDrafts() {
        for (id, state) in draftStates where state.pending != nil {
            state.upload?.cancel()
            draftStates[id]?.upload = Task { [weak self] in await self?.uploadDraft(id) }
        }
    }

    /// Reads the session's synced draft (on opening it, or when another device changed it).
    public func loadDraft(_ sessionId: String) async {
        guard let api, let session = sessions[sessionId] else { return }
        do {
            let record = try await api.readSessionDraft(sessionId: sessionId)
            var state = draftStates[sessionId] ?? DraftState()
            if let known = state.revision, let record, record.revision <= known { return }
            state.revision = record?.revision
            state.document = record?.content.flatMap { openDraft($0, session: session) }
            let text = state.document.map(SessionDraft.text(of:)) ?? ""
            state.syncedText = text
            draftStates[sessionId] = state
            // Text typed (or sent away) here and not yet up wins: the echo of an earlier upload,
            // arriving just after a message was sent, put the sent text back in the composer.
            if state.pending == nil { syncedDrafts[sessionId] = SyncedDraft(text: text, revision: record?.revision) }
        } catch {
            log.error("draft read: \(String(describing: error), privacy: .public)")
        }
    }

    private func openDraft(_ content: JSONValue, session: Session) -> JSONValue? {
        guard let payload = try? TranscriptMessage.open(content, session: session) else { return nil }
        return SessionDraft.document(fromPayload: payload, sessionId: session.id)
    }

    private func sealDraft(_ document: JSONValue, session: Session) throws -> JSONValue {
        let payload = SessionDraft.payload(sessionId: session.id, document: document)
        if session.isPlain { return ["t": "plain", "v": payload] }
        guard let cipher = session.cipher else { throw RPCError(message: "No session key", code: nil) }
        return ["t": "encrypted", "c": .string(try cipher.encryptBase64(payload))]
    }

    /// Writes the waiting text over the last known revision. When another device wrote first, it
    /// builds on theirs (keeping their other fields) and tries once more; this device's text wins,
    /// since it is the one being typed.
    private func uploadDraft(_ sessionId: String) async {
        guard let api, let session = sessions[sessionId], var state = draftStates[sessionId], let text = state.pending else { return }
        for _ in 0..<2 {
            let document = SessionDraft.withText(text, in: state.document ?? SessionDraft.document(text: text))
            let meaningful = SessionDraft.isMeaningful(document)
            // Nothing stored and nothing to store.
            if !meaningful, state.document == nil {
                var latest = draftStates[sessionId] ?? state
                if latest.pending == text { latest.pending = nil }
                latest.syncedText = text
                draftStates[sessionId] = latest
                savePendingDrafts()
                return
            }
            do {
                let content = meaningful ? try sealDraft(document, session: session) : nil
                switch try await api.mutateSessionDraft(sessionId: sessionId, expectedRevision: state.revision, content: content) {
                case .updated(let revision)?:
                    var latest = draftStates[sessionId] ?? state
                    latest.revision = revision
                    latest.document = meaningful ? document : nil
                    latest.syncedText = text
                    if latest.pending == text { latest.pending = nil }
                    draftStates[sessionId] = latest
                    savePendingDrafts()
                    // Text typed (or sent away) since this went up wins; a late echo mustn't bring it back.
                    if latest.pending == nil { syncedDrafts[sessionId] = SyncedDraft(text: text, revision: revision) }
                    return
                case .conflict(let revision)?:
                    let record = try await api.readSessionDraft(sessionId: sessionId)
                    state.revision = record?.revision ?? revision
                    state.document = record?.content.flatMap { openDraft($0, session: session) }
                    draftStates[sessionId]?.revision = state.revision
                    draftStates[sessionId]?.document = state.document
                case nil:
                    log.error("draft write: unexpected response")
                    return
                }
            } catch {
                log.error("draft write: \(String(describing: error), privacy: .public)")
                return
            }
        }
    }

    /// Another device changed a draft (`session-draft-updated`): read it when it is newer.
    private func handleDraftHint(_ payload: JSONValue) {
        let address = payload["address"]
        let sessionId = address?["sessionId"]?.stringValue
            ?? address?.stringValue.flatMap { $0.hasPrefix("session/") ? String($0.dropFirst("session/".count)).removingPercentEncoding : nil }
        guard let sessionId, sessions[sessionId] != nil else { return }
        if let revision = payload["revision"]?.intValue, let known = draftStates[sessionId]?.revision, revision <= known { return }
        Task { await loadDraft(sessionId) }
    }

    /// Commands the agent left running in the background, by session (newest first).
    public private(set) var backgroundCommands: [String: [BackgroundCommand]] = [:]

    public func refreshBackgroundCommands(_ sessionId: String) async {
        guard let api, let session = sessions[sessionId] else { return }
        do {
            let records = try await api.systemRecords(sessionId: sessionId, namespace: "activity", kind: "background_task.v1")
            let tasks = records.compactMap { record -> BackgroundCommand? in
                guard let payload = try? TranscriptMessage.open(record["content"] ?? .null, session: session) else {
                    log.error("background task record \(record["id"]?.stringValue ?? "?", privacy: .public) doesn't open")
                    return nil
                }
                return BackgroundCommand(payload: payload)
            }
            backgroundCommands[sessionId] = tasks.sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            log.error("background tasks: \(String(describing: error), privacy: .public)")
        }
    }

    /// Happier execution runs started from each session (delegations, reviews…), newest first.
    public private(set) var delegatedRuns: [String: [DelegatedRun]] = [:]

    /// Asks the session's runtime for its execution runs (`execution.run.list`). A session whose
    /// runtime is offline or predates runs keeps what was last seen.
    public func refreshDelegatedRuns(_ sessionId: String) async {
        do {
            let response = try await sessionRPC(sessionId, method: "execution.run.list", params: ["limit": 50])
            delegatedRuns[sessionId] = DelegatedRun.list(response)
        } catch let error as RPCError where error.code == "RPC_METHOD_NOT_AVAILABLE" {
            log.notice("execution runs: runtime unavailable for \(sessionId, privacy: .public)")
        } catch {
            log.error("execution runs: \(String(describing: error), privacy: .public)")
        }
    }

    /// A subagent's own thread: its latest messages, for reading what it did.
    public func subagentThread(_ sessionId: String, subagentId: String) async throws -> Transcript {
        guard let api, let session = sessions[sessionId] else { throw RPCError(message: "Not connected", code: nil) }
        let page = try await api.messages(sessionId: sessionId, limit: 200, sidechainId: subagentId)
        var thread = Transcript(sidechain: true)
        thread.apply(page.rows.compactMap { try? TranscriptMessage(row: $0, session: session) })
        return thread
    }

    /// Reads the latest message of each background subagent whose thread hasn't been seen (it may
    /// have run while the app was closed), so the list knows which ones have finished.
    public func refreshSubagentStatus(_ sessionId: String) async {
        guard let api, let session = sessions[sessionId], let transcript = transcripts[sessionId] else { return }
        for subagent in transcript.subagents where subagent.status == .running && subagent.lastActivityAt == nil {
            guard let page = try? await api.messages(sessionId: sessionId, limit: 1, sidechainId: subagent.id) else { continue }
            let rows = page.rows.compactMap { try? TranscriptMessage(row: $0, session: session) }
            if !rows.isEmpty { applyTranscript(rows, to: sessionId) }
        }
    }

    /// Cached aggregate reports, fetched only for visible sessions and their known descendants.
    public let sessionTokenUsage = KeyedStore<SessionTokenUsage>()
    @ObservationIgnored private var tokenUsageQueue: Set<String> = []
    @ObservationIgnored private var tokenUsageInFlight: String?
    @ObservationIgnored private var tokenUsageTask: Task<Void, Never>?
    @ObservationIgnored private var tokenUsageGeneration = UUID()

    public var sessionUsageParents: [String: String] {
        Dictionary(uniqueKeysWithValues: sessions.values.compactMap { session in
            session.parentSessionId.map { (session.id, $0) }
        })
    }

    public func tokenSummary(_ sessionId: String, parents: [String: String]? = nil) -> SessionTokenSummary {
        let parents = parents ?? sessionUsageParents
        let members = SessionTokenSummary.memberIds(sessionId, parents: parents)
        let reports = Dictionary(uniqueKeysWithValues: members.compactMap { id in
            sessionTokenUsage[id].map { (id, $0) }
        })
        return SessionTokenSummary(sessionId: sessionId, parents: parents, usage: reports)
    }

    public func loadSessionTokenUsage(_ sessionId: String, refresh: Bool = false) async {
        let members = SessionTokenSummary.memberIds(sessionId, parents: sessionUsageParents)
        for id in members where refresh || (sessionTokenUsage[id] == nil && tokenUsageInFlight != id) { tokenUsageQueue.insert(id) }
        await drainTokenUsageQueue()
    }

    /// A single queue bounds network work even when many sidebar rows appear together. Usage
    /// hints invalidate aggregates; adding a report's total would double-count replacement keys.
    private func drainTokenUsageQueue() async {
        if let tokenUsageTask { await tokenUsageTask.value; return }
        guard let api, !tokenUsageQueue.isEmpty else { return }
        let generation = tokenUsageGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let id = self.tokenUsageQueue.first {
                self.tokenUsageQueue.remove(id)
                self.tokenUsageInFlight = id
                let report = try? await api.sessionTokenUsage(sessionId: id)
                guard !Task.isCancelled, self.tokenUsageGeneration == generation else { return }
                self.sessionTokenUsage[id] = report ?? SessionTokenUsage(response: .null)
                self.tokenUsageInFlight = nil
            }
            if self.tokenUsageGeneration == generation { self.tokenUsageTask = nil }
        }
        tokenUsageTask = task
        await task.value
    }

    /// Usage limits left on the provider account each open session runs on.
    public private(set) var providerUsage: [String: ProviderUsage] = [:]

    /// Reads the provider usage the daemon published for the session; the newest snapshot wins
    /// when it has several (`sync/domains/accountUsage/selectors.ts`).
    public func refreshProviderUsage(_ sessionId: String) async {
        guard let api, let session = sessions[sessionId] else { return }
        var newest: ProviderUsage?
        for recordId in ProviderUsage.recordIds(in: session.metadata) {
            do {
                guard let snapshot = try await api.providerAccountUsage(recordId: recordId, machineKey: keys?.content.secretKey),
                      let usage = ProviderUsage(snapshot: snapshot) else {
                    log.error("provider usage \(recordId, privacy: .public): unreadable snapshot")
                    continue
                }
                if (usage.fetchedAt ?? .distantPast) >= (newest?.fetchedAt ?? .distantPast) { newest = usage }
            } catch {
                log.error("provider usage \(recordId, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        if providerUsage[sessionId] != newest { providerUsage[sessionId] = newest }
    }

    public func requestStop(_ sessionId: String) {
        stopRequest = StopRequest(sessionId: sessionId, thenArchive: false)
    }

    public func confirmStop(_ request: StopRequest) async {
        guard await stop(request.sessionId), request.thenArchive, let api else { return }
        // Archive succeeds once the server sees the session inactive (`sessionStopArchiveFlow.ts`).
        let deadline = ContinuousClock.now + .seconds(75)
        while true {
            do {
                try await api.archive(sessionId: request.sessionId)
                sessions[request.sessionId]?.archivedAt = .now
                return
            } catch let error as HTTPClient.ServerError where error.status == 409 && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            } catch {
                report(error)
                return
            }
        }
    }

    /// Stops the session's process: through its daemon, else by asking the runner to exit.
    private func stop(_ sessionId: String) async -> Bool {
        var outcome = SessionStop.Outcome.fallback
        if let machineId = sessions[sessionId]?.machineId {
            do {
                outcome = SessionStop.daemonOutcome(try await machineRPC(machineId, method: "stop-session", params: ["sessionId": .string(sessionId)],
                                                                         authorizingSession: sessionId))
            } catch is RPCError {
                outcome = .fallback
            } catch {
                report(error)
                return false
            }
        }
        if outcome == .fallback {
            do {
                outcome = SessionStop.runnerOutcome(try await sessionRPC(sessionId, method: "killSession", params: [:]))
            } catch let error as RPCError where RPCErrorCodes.unavailable.contains(error.code ?? "") {
                outcome = .failed(String(localized: "The session's machine isn't reachable right now. Try again when it's online."))
            } catch {
                report(error)
                return false
            }
        }
        switch outcome {
        case .stopped, .requested:
            return true
        case .failed(let message):
            lastError = message
            return false
        case .fallback:
            return false
        }
    }

    public func controls(for sessionId: String) -> SessionControls? {
        sessions[sessionId].map { SessionControls(metadata: $0.metadata, agentId: $0.agentId) }
    }

    public func setModel(_ modelId: String, in sessionId: String) async {
        await editMetadata(sessionId) { MetadataEdit.setModel(modelId, in: $0, now: $1) }
    }

    public func setEffort(_ effort: String, in sessionId: String) async {
        await editMetadata(sessionId) { MetadataEdit.setConfigOption("reasoning_effort", value: .string(effort), in: $0, now: $1) }
    }

    public func setUltracode(_ enabled: Bool, in sessionId: String) async {
        await editMetadata(sessionId) { MetadataEdit.setConfigOption("ultracode", value: .string(enabled ? "true" : "false"), in: $0, now: $1) }
    }

    public func setPermissionMode(_ mode: PermissionMode, in sessionId: String) async {
        await editMetadata(sessionId) { MetadataEdit.setPermissionMode(mode, in: $0, now: $1) }
    }

    public func setNotificationsMuted(_ muted: Bool, in sessionId: String) async {
        await editMetadata(sessionId) { MetadataEdit.setNotificationsMuted(muted, in: $0, now: $1) }
    }

    /// Read-modify-write of the full session metadata with optimistic concurrency
    /// (`update-metadata`, retried on version mismatch like `updateSessionMetadataWithRetry.ts`).
    private func editMetadata(_ sessionId: String, _ edit: (JSONValue, Double) -> JSONValue) async {
        guard let socket, connection == .online else {
            lastError = "Not connected. Try again when the connection is back."
            return
        }
        do {
            for _ in 0..<6 {
                guard let session = sessions[sessionId] else { return }
                let next = edit(session.metadata, ServerClock.nowMs())
                if next == session.metadata { return }
                let ack = try await socket.emitWithAck("update-metadata", [
                    "sid": .string(sessionId),
                    "expectedVersion": .number(Double(session.metadataVersion)),
                    "metadata": .string(try session.encodeDocument(next)),
                ])
                guard let response = ack.first, let version = response["version"]?.intValue else {
                    throw RPCError(message: "Invalid metadata update response", code: nil)
                }
                try sessions[sessionId]?.apply(update: ["metadata": ["value": response["metadata"] ?? .null, "version": .number(Double(version))]])
                switch response["result"]?.stringValue {
                case "success": return
                case "version-mismatch": continue
                default: throw RPCError(message: response["message"]?.stringValue ?? "Metadata update failed", code: response["result"]?.stringValue)
                }
            }
            throw RPCError(message: "The session changed too often to save this setting. Try again.", code: "version-mismatch")
        } catch { report(error) }
    }

    /// Session-scoped RPC through the server relay (`apiSocket.ts:334-405`).
    public func sessionRPC(_ sessionId: String, method: String, params: JSONValue, timeout: Duration = .seconds(30)) async throws -> JSONValue {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        // Back from the background the connection is still returning: wait for it, within this
        // call's own budget, rather than failing an upload made in that moment.
        let socket = try await connectedSocket(until: deadline, clock: clock)
        guard let session = sessions[sessionId] else { throw RPCError(message: "Unknown session", code: nil) }
        let encodedParams: JSONValue = session.isPlain ? params : .string(try session.encodeDocument(params))
        let ack = try await socket.emitWithAck(
            "rpc-call", ["method": .string("\(sessionId):\(method)"), "params": encodedParams], timeout: deadline - clock.now)
        guard let response = ack.first else { throw RPCError(message: "Empty RPC response", code: nil) }
        guard response["ok"]?.boolValue == true else {
            throw RPCError(message: response["error"]?.stringValue ?? "RPC failed", code: response["errorCode"]?.stringValue)
        }
        var result = response["result"] ?? .null
        if !session.isPlain, let ciphertext = result.stringValue { result = try session.cipher!.decryptBase64(ciphertext) }
        if result["ok"]?.boolValue == false || (result["error"]?.stringValue != nil && result["ok"] == nil) {
            throw RPCError(
                message: result["errorMessage"]?.stringValue ?? result["error"]?.stringValue ?? "RPC failed",
                code: result["errorCode"]?.stringValue)
        }
        return result
    }

    /// The relay connection once it's up, checked every tenth of a second until `deadline`. Only
    /// a signed-in store keeps reconnecting; signed out there is nothing to wait for.
    private func connectedSocket(until deadline: ContinuousClock.Instant, clock: ContinuousClock) async throws -> SocketIOClient {
        while true {
            if let socket, connection == .online { return socket }
            guard phase == .ready, clock.now < deadline else { throw RPCError(message: "Not connected", code: nil) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Failure of something the user asked for: logged and shown as a readable alert.
    // MARK: - Push notifications

    /// This device as an APNs endpoint (from `didRegisterForRemoteNotificationsWithDeviceToken`).
    public struct PushDevice: Sendable {
        public let deviceToken: Data
        public let development: Bool
        public let bundleId: String

        public init(deviceToken: Data, development: Bool, bundleId: String) {
            self.deviceToken = deviceToken
            self.development = development
            self.bundleId = bundleId
        }
    }

    private static let pushTokenKey = "happier.pushToken"

    public func setPushDevice(_ device: PushDevice) {
        pushDevice = device
        Task { await registerPushToken() }
    }

    /// Registers this device's APNs token with the account (idempotent upsert).
    private func registerPushToken() async {
        guard let device = pushDevice, let api else { return }
        let token = PushNotifications.apnsToken(deviceToken: device.deviceToken, development: device.development, bundleId: device.bundleId)
        do {
            try await api.registerPushToken(token, clientServerUrl: server)
            UserDefaults.standard.set(token, forKey: Self.pushTokenKey)
            log.notice("push token registered (\(device.development ? "sandbox" : "production", privacy: .public))")
        } catch {
            logBackground(error, "push registration")
        }
    }

    /// Opens the notified session, answering a permission request first when an action button was
    /// used. A reply typed in the notification is sent without opening anything; false if it failed.
    @discardableResult
    public func handle(_ tap: PushTap) async -> Bool {
        if let text = tap.reply, let sessionId = tap.sessionId {
            return await replyFromNotification(text, to: sessionId)
        }
        // Allow or Deny on the notification (the lock screen, the Apple Watch): answered in the
        // background without opening the app.
        if let permission = tap.permission, let sessionId = tap.sessionId {
            return await permissionFromNotification(permission, in: sessionId)
        }
        pendingPushTap = tap
        await handlePendingPushTap()
        return true
    }

    /// The app may have been woken in the background just for this: sign in from the saved
    /// credentials and fetch the one session rather than wait for the whole list.
    private func replyFromNotification(_ text: String, to sessionId: String) async -> Bool {
        guard await sessionForNotification(sessionId) else { return false }
        guard await send(text, to: sessionId) else { return false }
        markRead(sessionId)
        return true
    }

    private func permissionFromNotification(_ permission: PushTap.Permission, in sessionId: String) async -> Bool {
        guard await sessionForNotification(sessionId) else { return false }
        do {
            try await sendPermissionReply(permission.allow ? .allow : .deny(reason: nil), to: (permission.requestId, permission.tool), in: sessionId)
            return true
        } catch {
            log.error("permission from notification failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Woken just for a notification's action: signed in from the saved credentials, with the
    /// one session it's about rather than the whole list.
    private func sessionForNotification(_ sessionId: String) async -> Bool {
        restore()
        guard phase == .ready, let api else { return false }
        guard sessions[sessionId] == nil else { return true }
        do {
            guard let row = try await api.session(id: sessionId) else { return false }
            sessions[sessionId] = try Session(row: row, keys: keys)
            return true
        } catch {
            log.error("notification: session fetch failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func handlePendingPushTap() async {
        guard hasLoadedSessions, let tap = pendingPushTap else { return }
        pendingPushTap = nil
        guard let sessionId = tap.sessionId, sessions[sessionId] != nil else { return }
        openRequest = sessionId
    }

    private func report(_ error: Error) {
        if UserFacingError.isSilent(error) {
            log.notice("operation cancelled")
            return
        }
        log.error("\(String(describing: error), privacy: .public)")
        lastError = UserFacingError.message(for: error)
    }

    /// Failure of automatic sync work: logged only; the sync loop retries and the connection
    /// indicator shows the state.
    private func logBackground(_ error: Error, _ context: StaticString) {
        if UserFacingError.isSilent(error) { return }
        log.error("\(context, privacy: .public) failed: \(String(describing: error), privacy: .public)")
    }
}

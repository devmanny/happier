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

    public private(set) var phase: Phase = .launching
    public private(set) var connection: Connection = .offline
    public private(set) var server: URL
    public private(set) var sessions: [String: Session] = [:]
    public private(set) var transcripts: [String: Transcript] = [:]
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
    @ObservationIgnored private var openSessionIds: Set<String> = []
    @ObservationIgnored private var loadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var loadedTranscripts: Set<String> = []
    @ObservationIgnored private var pendingFetches: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingFetchDirty: Set<String> = []
    @ObservationIgnored private var pushDevice: PushDevice?
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
        self.server = server ?? UserDefaults.standard.url(forKey: "happier.server") ?? Self.defaultServer
    }

    // MARK: - Account

    public func restore() {
        do {
            if let credentials = try credentialStore.load(server: server) { activate(credentials) } else { phase = .signedOut }
        } catch {
            log.error("credential load failed: \(String(describing: error), privacy: .public)")
            phase = .signedOut
        }
    }

    public func signIn(_ credentials: Credentials, server: URL) throws {
        self.server = server
        UserDefaults.standard.set(server, forKey: "happier.server")
        try credentialStore.save(credentials, server: server)
        activate(credentials)
    }

    public func signOut() {
        if let api, let token = UserDefaults.standard.string(forKey: Self.pushTokenKey) {
            UserDefaults.standard.removeObject(forKey: Self.pushTokenKey)
            Task { try? await api.deletePushToken(token) }
        }
        credentialStore.delete(server: server)
        syncTask?.cancel()
        let socket = self.socket
        Task { await socket?.disconnect() }
        credentials = nil
        keys = nil
        api = nil
        self.socket = nil
        sessions = [:]
        transcripts = [:]
        hasLoadedSessions = false
        pendingQueues = [:]
        draftSeeds = [:]
        openRequest = nil
        machines = []
        openSessionIds = []
        loadTasks.values.forEach { $0.cancel() }
        loadTasks = [:]
        loadedTranscripts = []
        connection = .offline
        phase = .signedOut
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
        pins = MessagePins(scope: "\(server.host() ?? server.absoluteString)/\(credentials.accountId ?? "account")")
        phase = .ready
        syncTask?.cancel()
        syncTask = Task { await runSync() }
    }

    // MARK: - Session list

    public var sessionList: [Session] {
        sessions.values.filter(\.isUserFacing).sorted { $0.sortDate > $1.sortDate }
    }

    /// Reloads the session list. Background refreshes (sync loop, reconnects) only log failures;
    /// a user-initiated refresh (pull to refresh) shows them.
    public func refreshSessions(userInitiated: Bool = false) async {
        guard let api else { return }
        isLoadingSessions = true
        defer { isLoadingSessions = false }
        do {
            let rows = try await api.listSessions()
            var next: [String: Session] = [:]
            var failures = 0
            for row in rows {
                do {
                    let session = try Session(row: row, keys: keys)
                    next[session.id] = session
                } catch {
                    failures += 1
                }
            }
            if failures > 0 { log.notice("\(failures) sessions could not be decrypted") }
            undecryptableSessionCount = failures
            sessions = next
            hasLoadedSessions = true
            Task { await handlePendingPushTap() }
            for (id, session) in next where transcripts[id] != nil {
                transcripts[id]?.apply(agentState: session.agentState)
            }
        } catch {
            if userInitiated { report(error) } else { logBackground(error, "session list refresh") }
        }
    }

    // MARK: - App lifecycle

    /// iOS freezes networking while the app is in the background: close the socket cleanly so
    /// nothing is left half-open, and reconnect + resync as soon as the app is back.
    public func appDidEnterBackground() {
        guard phase == .ready else { return }
        syncTask?.cancel()
        syncTask = nil
        let socket = self.socket
        Task { await socket?.disconnect() }
        connection = .offline
    }

    public func appDidBecomeActive() {
        guard phase == .ready, syncTask == nil else { return }
        syncTask = Task { await runSync() }
    }

    // MARK: - Realtime

    private func runSync() async {
        var backoff: Duration = .seconds(1)
        await refreshSessions()
        while !Task.isCancelled, let token = credentials?.token {
            connection = .connecting
            let socket = SocketIOClient(
                serverURL: server, path: "/v1/updates",
                auth: ["token": .string(token), "clientType": "user-scoped", "clientPurpose": "sync"])
            self.socket = socket
            do {
                try await socket.connect()
                connection = .online
                backoff = .seconds(1)
                await refreshSessions()
                for id in openSessionIds { await catchUp(id) }
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
            await handleUpdate(payload["body"] ?? .null)
        case "ephemeral":
            if payload["type"]?.stringValue == "activity", let id = payload["id"]?.stringValue {
                sessions[id]?.apply(activity: payload)
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
                sessions[sid]?.seq = max(session.seq, message.seq)
                sessions[sid]?.meaningfulActivityAt = message.createdAt
                guard let transcript = transcripts[sid] else { return }
                if transcript.maxSeq > 0, message.seq > transcript.maxSeq + 1 { await catchUp(sid) }
                transcripts[sid]?.apply([message])
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
        case "delete-session":
            if let sid = body["sid"]?.stringValue {
                sessions[sid] = nil
                transcripts[sid] = nil
            }
        default:
            break
        }
    }

    // MARK: - Transcript

    /// Starts loading a transcript. The load is owned by the store, not by the calling view, so a
    /// view that SwiftUI recreates or dismisses mid-flight cannot leave the transcript half-loaded.
    public func open(_ id: String) {
        openSessionIds.insert(id)
        guard loadTasks[id] == nil else { return }
        loadTasks[id] = Task {
            await load(id)
            loadTasks[id] = nil
        }
    }

    private func load(_ id: String) async {
        guard let session = sessions[id], let api else {
            log.error("open: unknown session or signed out")
            return
        }
        if transcripts[id] == nil {
            var transcript = Transcript()
            transcript.apply(agentState: session.agentState)
            transcripts[id] = transcript
        }
        if loadedTranscripts.contains(id) {
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
                loadedTranscripts.insert(id)
            } catch {
                transcriptErrors[id] = UserFacingError.message(for: error)
                log.error("open failed: \(String(describing: error), privacy: .public)")
            }
        }
        refreshPending(id)
        markRead(id)
    }

    public func close(_ id: String) {
        openSessionIds.remove(id)
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
        guard let api, var after = transcripts[id]?.maxSeq, after > 0 else { return }
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
        transcripts[id]?.apply(messages)
        if rows.count > 1 {
            log.notice("apply: decode=\(decoded - started, privacy: .public) reduce=\(clock.now - decoded, privacy: .public) rows=\(rows.count, privacy: .public)")
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
        Task { try? await api.markRead(sessionId: id) }
    }

    // MARK: - Actions

    public func send(_ text: String, attachments: [AttachmentDraft] = [], to id: String) async {
        guard sessions[id] != nil, let api else {
            log.error("send: unknown session or signed out")
            return
        }
        log.notice("send: \(text.count, privacy: .public) chars, \(attachments.count, privacy: .public) attachments")
        let localId = UUID().uuidString.lowercased()
        if transcripts[id] == nil { transcripts[id] = Transcript() }
        transcripts[id]?.addPending(localId: localId, text: text, attachments: attachments.map(\.name))
        do {
            var uploaded: [UploadedAttachment] = []
            for draft in attachments {
                uploaded.append(try await upload(draft, to: id, messageLocalId: localId))
            }
            guard let session = sessions[id] else { return }
            var meta = controls(for: id)?.messageMeta.objectValue ?? [:]
            meta["source"] = "ui"
            meta["sentFrom"] = .string(sentFrom)
            var body = text
            if !uploaded.isEmpty {
                let message = AttachmentMessage(text: text, attachments: uploaded)
                body = message.text
                meta.merge(message.meta) { $1 }
            }
            let record: JSONValue = ["role": "user", "content": ["type": "text", "text": .string(body)], "meta": .object(meta)]
            let content: JSONValue = session.isPlain ? ["t": "plain", "v": record] : .string(try session.encodeDocument(record))
            let action = SendDecision.action(for: text, session: session)
            try await api.enqueueUserMessage(sessionId: id, localId: localId, content: content, action: action)
            log.notice("send: \(action.rawValue, privacy: .public)")
        } catch {
            transcripts[id]?.removePending(localId: localId)
            report(error)
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
    public func machineRPC(_ machineId: String, method: String, params: JSONValue, timeout: Duration = .seconds(30)) async throws -> JSONValue {
        guard let socket, connection == .online, let api else { throw RPCError(message: "Not connected", code: nil) }
        let machine: Machine
        if let cached = machines.first(where: { $0.id == machineId }) {
            machine = cached
        } else {
            guard let row = try await api.machine(id: machineId) else { throw RPCError(message: "Machine not found", code: nil) }
            machine = try Machine(row: row, keys: keys)
        }
        let encoded: JSONValue = try machine.cipher.map { .string(try $0.encryptBase64(params)) } ?? params
        let ack = try await socket.emitWithAck("rpc-call", [
            "method": .string("\(machineId):\(method)"), "params": encoded,
            "timeoutMs": .number(Double(timeout.components.seconds * 1000)),
        ], timeout: timeout + .seconds(5))
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
            machines = rows.compactMap { try? Machine(row: $0, keys: keys) }
                .sorted { ($0.active ? 0 : 1, $0.name.lowercased()) < ($1.active ? 0 : 1, $1.name.lowercased()) }
        } catch { report(error) }
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

    public enum SpawnOutcome: Equatable, Sendable {
        case created(sessionId: String)
        /// The folder doesn't exist; ask, then retry with `approveNewDirectory: true`.
        case needsDirectoryApproval(String)
        case failed(String)
    }

    /// Starts an agent in a folder on a machine (`spawn-happy-session`, `spawnSessionPayload.ts`),
    /// waits for the session to appear, sends the first message and opens it.
    public func createSession(machineId: String, directory: String, agentId: String, permissionMode: PermissionMode,
                              firstMessage: String, approveNewDirectory: Bool = false) async -> SpawnOutcome {
        let nonce = UUID().uuidString.lowercased()
        let params = SpawnRequest.params(directory: directory, agentId: agentId, permissionMode: permissionMode,
                                         nonce: nonce, approveNewDirectory: approveNewDirectory)
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
            let message = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty, sessions[sessionId] != nil { await send(message, to: sessionId) }
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
            try await api.setPendingAction(sessionId: id, localId: localId, action: .steerNow)
        }
    }

    /// Stops the current turn and sends this message (server `interrupt_and_send` while busy).
    public func sendPendingNow(_ localId: String, in id: String) async {
        await pendingMutation(id, localId) { api in
            try await api.setPendingAction(sessionId: id, localId: localId, action: .sendNow)
        }
    }

    /// Puts a blocked or discarded message back in line.
    public func requeuePending(_ localId: String, in id: String) async {
        let discarded = pendingQueues[id]?.first { $0.localId == localId }?.state == .discarded
        await pendingMutation(id, localId) { api in
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

    private func pendingMutation(_ id: String, _ localId: String, _ work: (HappierAPI) async throws -> Void) async {
        guard let api else { return }
        do { try await work(api) } catch let error as HTTPClient.ServerError where error.status == 409 || error.status == 404 {
            lastError = String(localized: "This pending message changed while the action was being applied. The list was refreshed.")
        } catch { report(error) }
        refreshPending(id)
    }

    /// Default `attachmentsUploadsMaxFileBytes` of the official client (25 MiB).
    public static let maxAttachmentBytes = 25 * 1024 * 1024

    /// Uploads one file to the session's machine through the daemon's bulk-transfer RPCs
    /// (`daemonSessionAttachments.ts`); the daemon applies its default attachment location.
    private func upload(_ draft: AttachmentDraft, to sessionId: String, messageLocalId: String) async throws -> UploadedAttachment {
        guard draft.data.count <= Self.maxAttachmentBytes else {
            throw RPCError(message: "\(draft.name) is larger than 25 MB.", code: "attachment_too_large")
        }
        let initResponse = try await sessionRPC(sessionId, method: "daemon.bulkTransfer.upload.init", params: [
            "t": "session_attachment_upload_v1",
            "messageLocalId": .string(messageLocalId),
            "fileName": .string(draft.name),
            "sizeBytes": .number(Double(draft.data.count)),
        ])
        guard let uploadId = initResponse["uploadId"]?.stringValue,
              let chunkSize = initResponse["chunkSizeBytes"]?.intValue, chunkSize > 0,
              let recipient = initResponse["recipientPublicKeyBase64"]?.stringValue
        else { throw RPCError(message: "The computer rejected the upload.", code: "upload_init_invalid") }
        do {
            var index = 0
            var offset = 0
            while offset < draft.data.count {
                let end = min(offset + chunkSize, draft.data.count)
                let chunk = try TransferChunk.encrypt(draft.data.subdata(in: offset..<end), uploadId: uploadId, index: index,
                                                      recipientPublicKeyBase64: recipient)
                _ = try await sessionRPC(sessionId, method: "daemon.bulkTransfer.upload.chunk", params: [
                    "uploadId": .string(uploadId), "index": .number(Double(index)),
                    "payloadBase64": .string(chunk.payloadBase64),
                    "encryptedDataKeyEnvelopeBase64": .string(chunk.encryptedDataKeyEnvelopeBase64),
                ])
                index += 1
                offset = end
            }
            let finalized = try await sessionRPC(sessionId, method: "daemon.bulkTransfer.upload.finalize", params: ["uploadId": .string(uploadId)])
            guard let path = finalized["path"]?.stringValue else {
                throw RPCError(message: "The computer didn't confirm the upload.", code: "upload_finalize_invalid")
            }
            return UploadedAttachment(name: draft.name, path: path, mimeType: draft.mimeType,
                                      sizeBytes: finalized["sizeBytes"]?.intValue ?? draft.data.count, sha256: finalized["sha256"]?.stringValue)
        } catch {
            do { _ = try await sessionRPC(sessionId, method: "daemon.bulkTransfer.upload.abort", params: ["uploadId": .string(uploadId)]) } catch {
                log.notice("upload abort failed: \(String(describing: error), privacy: .public)")
            }
            throw error
        }
    }

    public func reply(_ reply: PermissionReply, to request: (id: String, tool: String), in sessionId: String) async {
        let agentId = sessions[sessionId]?.agentId
        do {
            _ = try await sessionRPC(sessionId, method: "permission", params: reply.payload(requestId: request.id, tool: request.tool, agentId: agentId))
            if reply.abortsTurn(agentId: agentId) { await abort(sessionId) }
        } catch { report(error) }
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

    public func abort(_ sessionId: String) async {
        do {
            _ = try await sessionRPC(sessionId, method: "abort", params: [
                "reason": "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed.",
            ])
        } catch let error as RPCError where error.code == "RPC_METHOD_NOT_AVAILABLE" {
            // Session runtime is offline: nothing to abort.
        } catch { report(error) }
    }

    public func archive(_ sessionId: String) async {
        guard let api else { return }
        do {
            try await api.archive(sessionId: sessionId)
            sessions[sessionId]?.archivedAt = .now
        } catch { report(error) }
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
        guard let socket, connection == .online else { throw RPCError(message: "Not connected", code: nil) }
        guard let session = sessions[sessionId] else { throw RPCError(message: "Unknown session", code: nil) }
        let encodedParams: JSONValue = session.isPlain ? params : .string(try session.encodeDocument(params))
        let ack = try await socket.emitWithAck(
            "rpc-call", ["method": .string("\(sessionId):\(method)"), "params": encodedParams], timeout: timeout)
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

    /// Failure of something the user asked for: logged and shown as a readable alert.
    // MARK: - Push notifications

    /// This device as an APNs endpoint (from `didRegisterForRemoteNotificationsWithDeviceToken`).
    public struct PushDevice: Sendable {
        public let deviceToken: Data
        public let development: Bool
        public let bundleId: String
        /// Expo project whose APNs credentials deliver to this bundle id.
        public let expoProjectId: String

        public init(deviceToken: Data, development: Bool, bundleId: String, expoProjectId: String) {
            self.deviceToken = deviceToken
            self.development = development
            self.bundleId = bundleId
            self.expoProjectId = expoProjectId
        }
    }

    private static let pushTokenKey = "happier.expoPushToken"
    private static let installationIdKey = "happier.installationId"

    public func setPushDevice(_ device: PushDevice) {
        pushDevice = device
        Task { await registerPushToken() }
    }

    /// Exchanges the APNs token for an Expo token and registers it with the account (idempotent upsert).
    private func registerPushToken() async {
        guard let device = pushDevice, let api else { return }
        let defaults = UserDefaults.standard
        let installationId = defaults.string(forKey: Self.installationIdKey).flatMap(UUID.init(uuidString:)) ?? {
            let id = UUID()
            defaults.set(id.uuidString, forKey: Self.installationIdKey)
            return id
        }()
        do {
            let expo = HTTPClient(baseURL: URL(string: "https://exp.host")!)
            let response = try await expo.post("/--/api/v2/push/getExpoPushToken", PushNotifications.expoTokenRequest(
                deviceToken: device.deviceToken, installationId: installationId, development: device.development,
                bundleId: device.bundleId, projectId: device.expoProjectId))
            guard let token = PushNotifications.expoToken(from: response) else {
                throw HTTPClient.ServerError(status: 200, path: "getExpoPushToken", body: response)
            }
            try await api.registerPushToken(token, clientServerUrl: server)
            defaults.set(token, forKey: Self.pushTokenKey)
            log.notice("push token registered (\(device.development ? "sandbox" : "production", privacy: .public))")
        } catch {
            logBackground(error, "push registration")
        }
    }

    /// Opens the notified session, answering a permission request first when an action button was used.
    public func handle(_ tap: PushTap) async {
        pendingPushTap = tap
        await handlePendingPushTap()
    }

    private func handlePendingPushTap() async {
        guard hasLoadedSessions, let tap = pendingPushTap else { return }
        pendingPushTap = nil
        guard let sessionId = tap.sessionId, sessions[sessionId] != nil else { return }
        if let permission = tap.permission {
            await reply(permission.allow ? .allow : .deny(reason: nil), to: (permission.requestId, permission.tool), in: sessionId)
        }
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

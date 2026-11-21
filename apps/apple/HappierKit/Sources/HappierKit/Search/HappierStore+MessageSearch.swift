import Foundation

/// A conversation to open at one of its messages (a message-search result).
public struct MessageRequest: Equatable, Hashable, Sendable {
    public let sessionId: String
    public let seq: Int

    public init(sessionId: String, seq: Int) {
        self.sessionId = sessionId
        self.seq = seq
    }
}

/// Message search through the daemons that keep a conversation index (`MessageSearch`). Each
/// machine switches it on or off for itself; a search asks every online machine at once and
/// merges what the ones with search on found.
extension HappierStore {
    public struct MessageSearchMachine: Equatable, Hashable, Sendable {
        public let id: String
        public let name: String
    }

    /// A machine still reading older conversations, and how far it got.
    public struct MessageSearchBackfill: Equatable, Sendable {
        public let machineName: String
        public let coverage: MessageSearch.Coverage
    }

    public enum MessageSearchOutcome: Equatable, Sendable {
        /// `cursors`: the next page of each machine that has more.
        case results(hits: [MessageSearch.Hit], cursors: [String: String], backfilling: [MessageSearchBackfill])
        /// Online machines that can search, none of them with search on.
        case off(machines: [MessageSearchMachine])
        /// The online machines' CLIs predate conversation search.
        case outdated(machineNames: [String])
        /// No machine is online.
        case unavailable
        case failed(String)
    }

    static let messageSearchTimeout: Duration = .seconds(15)

    /// One search across the online machines; with `cursors`, the next page of each of those machines.
    public func searchMessages(query: String, order: MessageSearch.Order = .relevance,
                               cursors: [String: String]? = nil) async -> MessageSearchOutcome {
        var online = machines.filter { $0.isOnline(at: presenceDate()) }
        if online.isEmpty, cursors == nil {
            await refreshMachines()
            online = machines.filter { $0.isOnline(at: presenceDate()) }
        }
        if let cursors { online = online.filter { cursors[$0.id] != nil } }
        guard !online.isEmpty else { return .unavailable }

        // Every machine at once; answers are read back in the machine list's order.
        let asks = online.map { machine in
            let request = MessageSearch.request(query: query, cursor: cursors?[machine.id], order: order)
            return (machine, Task { @MainActor () -> MessageSearch.Answer? in
                do {
                    return MessageSearch.answer(try await self.machineRPC(machine.id, method: MessageSearch.method, params: request,
                                                                          timeout: Self.messageSearchTimeout))
                } catch {
                    self.logBackground(error, "message search on a machine")
                    return nil
                }
            })
        }
        var answers: [(Machine, MessageSearch.Answer?)] = []
        await withTaskCancellationHandler {
            for (machine, ask) in asks { answers.append((machine, await ask.value)) }
        } onCancel: {
            for (_, ask) in asks { ask.cancel() }
        }
        if Task.isCancelled { return .unavailable }

        var pages: [(Machine, MessageSearch.Page)] = []
        var off: [MessageSearchMachine] = []
        var outdated: [String] = []
        var failure: String?
        for (machine, answer) in answers {
            switch answer {
            case .page(let page): pages.append((machine, page))
            case .refused(.off): off.append(MessageSearchMachine(id: machine.id, name: machine.name))
            case .refused(.outdated): outdated.append(machine.name)
            case .refused(.failed(let message)): failure = failure ?? message
            case nil: continue
            }
        }
        if !pages.isEmpty {
            return .results(
                hits: MessageSearch.merge(pages.map(\.1.hits), order: order),
                cursors: Dictionary(uniqueKeysWithValues: pages.compactMap { machine, page in page.nextCursor.map { (machine.id, $0) } }),
                backfilling: pages.compactMap { machine, page in
                    page.coverage.backfillComplete ? nil : MessageSearchBackfill(machineName: machine.name, coverage: page.coverage)
                })
        }
        if let failure { return .failed(failure) }
        if !off.isEmpty { return .off(machines: off) }
        if !outdated.isEmpty { return .outdated(machineNames: outdated) }
        return .unavailable
    }

    /// Conversation search on one machine; nil when its CLI predates it.
    public func messageSearchStatus(machineId: String) async throws -> MessageSearch.Status? {
        do {
            return MessageSearch.status(try await machineRPC(machineId, method: MessageSearch.statusMethod, params: .object([:])))
        } catch let error as RPCError where error.code.map(RPCErrorCodes.unavailable.contains) == true {
            return nil
        }
    }

    /// Switches conversation search on one machine; `deleteIndex` (turning off) also removes its
    /// local index. Nil, with the error reported, when the machine refused.
    public func setMessageSearch(machineId: String, enabled: Bool, deleteIndex: Bool = false) async -> MessageSearch.Status? {
        do {
            let result = try await machineRPC(machineId, method: MessageSearch.switchMethod,
                                              params: MessageSearch.switchRequest(enabled: enabled, deleteIndex: deleteIndex))
            guard let status = MessageSearch.status(result), status.enabled == enabled else {
                lastError = enabled
                    ? String(localized: "The machine didn't turn on conversation search.")
                    : String(localized: "The machine didn't turn off conversation search.")
                return nil
            }
            return status
        } catch {
            report(error)
            return nil
        }
    }

    /// Opens the conversation at the message a search found.
    public func openMessage(sessionId: String, seq: Int) async {
        messageRequest = MessageRequest(sessionId: sessionId, seq: seq)
        await openRelatedSession(sessionId)
    }

    /// The device's own search while no machine can answer: the conversations already loaded here.
    public func localMessageHits(query: String, limit: Int = MessageSearch.pageSize) -> [MessageSearch.Hit] {
        let loaded = transcripts.keys.compactMap { id in transcripts[id].map { (sessionId: id, items: $0.items) } }
        return MessageSearch.localHits(query: query, transcripts: loaded, limit: limit)
    }
}

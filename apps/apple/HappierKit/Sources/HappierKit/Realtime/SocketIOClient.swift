import Foundation
import os

/// Minimal Socket.IO v4 client (websocket transport only) for the Happier `/v1/updates` endpoint.
/// One instance owns one connection; reconnection policy belongs to the caller (`SyncEngine`).
public actor SocketIOClient {
    public enum Event: Sendable {
        case event(name: String, args: [JSONValue])
        case disconnected(reason: String)
    }

    public struct ConnectError: Error, CustomStringConvertible {
        public let message: String
        public var description: String { "Socket.IO connect rejected: \(message)" }
    }

    public struct AckTimeout: Error {}
    public struct NotConnected: Error {}

    private static let log = Logger(subsystem: "dev.happier.apple", category: "socket")

    private let url: URL
    private let auth: JSONValue
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var nextAckId = 0
    private var pendingAcks: [Int: CheckedContinuation<[JSONValue], Error>] = [:]
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var watchdog: Task<Void, Never>?
    private var heartbeatDeadline: Duration = .seconds(45)
    private var lastHeartbeat = ContinuousClock.now
    private var closed = false

    public nonisolated let events: AsyncStream<Event>
    private let eventSink: AsyncStream<Event>.Continuation

    /// - Parameters:
    ///   - serverURL: e.g. `https://api.happier.dev`
    ///   - path: Socket.IO path, `/v1/updates` for Happier.
    ///   - auth: handshake `auth` object (token, clientType, ...).
    public init(serverURL: URL, path: String, auth: JSONValue, session: URLSession = .shared) {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = base + path + "/"
        components.queryItems = [URLQueryItem(name: "EIO", value: "4"), URLQueryItem(name: "transport", value: "websocket")]
        self.url = components.url!
        self.auth = auth
        self.session = session
        (events, eventSink) = AsyncStream.makeStream(of: Event.self)
    }

    /// Opens the websocket and completes the namespace handshake.
    public func connect() async throws {
        let task = session.webSocketTask(with: url)
        // URLSession defaults to 1 MiB per frame; transcript updates carrying images exceed it and
        // the socket would drop with "Message too long". The server bounds message size
        // (`HAPPIER_SOCKET_MAX_HTTP_BUFFER_SIZE`, 25 MB by default), so the client adds no cap.
        task.maximumMessageSize = .max
        self.task = task
        task.resume()
        Task { await self.receiveLoop(task) }
        try await withCheckedThrowingContinuation { self.connectContinuation = $0 }
        startWatchdog()
    }

    public func disconnect() {
        guard !closed else { return }
        if let task { Task { try? await task.send(.string(try SocketIOPacket.disconnect.encode())) } }
        shutdown(reason: "client disconnect")
    }

    /// Fire-and-forget event.
    public func emit(_ name: String, _ args: JSONValue...) async throws {
        try await send(.event(name: name, args: args, ackId: nil))
    }

    /// Event with acknowledgement; returns the ack arguments.
    public func emitWithAck(_ name: String, _ args: JSONValue..., timeout: Duration = .seconds(30)) async throws -> [JSONValue] {
        let id = nextAckId
        nextAckId += 1
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.failAck(id, AckTimeout())
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pendingAcks[id] = continuation
            Task {
                do { try await self.send(.event(name: name, args: args, ackId: id)) }
                catch { self.failAck(id, error) }
            }
        }
    }

    /// Reply to a server event that requested an acknowledgement.
    public func ack(_ id: Int, _ args: JSONValue...) async throws {
        try await send(.ack(id: id, args: args))
    }

    // MARK: - Internals

    private func send(_ packet: SocketIOPacket) async throws {
        guard let task, !closed else { throw NotConnected() }
        try await task.send(.string(try packet.encode()))
    }

    private func failAck(_ id: Int, _ error: Error) {
        pendingAcks.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !closed {
            let message: URLSessionWebSocketTask.Message
            do { message = try await task.receive() } catch {
                shutdown(reason: error.localizedDescription)
                return
            }
            guard case .string(let text) = message else { continue }
            do { try await handle(try SocketIOPacket.decode(text)) } catch {
                Self.log.error("\(String(describing: error), privacy: .public)")
            }
        }
    }

    private func handle(_ packet: SocketIOPacket) async throws {
        switch packet {
        case .open(let info):
            if let interval = info["pingInterval"]?.intValue, let timeout = info["pingTimeout"]?.intValue {
                heartbeatDeadline = .milliseconds(interval + timeout)
            }
            lastHeartbeat = .now
            try await send(.connect(auth))
        case .ping:
            lastHeartbeat = .now
            try await send(.pong)
        case .connect:
            connectContinuation?.resume()
            connectContinuation = nil
        case .connectError(let info):
            let message = info["message"]?.stringValue ?? "unknown"
            connectContinuation?.resume(throwing: ConnectError(message: message))
            connectContinuation = nil
            shutdown(reason: "connect error: \(message)")
        case .event(let name, let args, let ackId):
            if let ackId {
                // The Happier UI registers no client RPC handlers; answer so the server never waits.
                try await send(.ack(id: ackId, args: [["ok": false, "error": "not supported"]]))
            }
            eventSink.yield(.event(name: name, args: args))
        case .ack(let id, let args):
            pendingAcks.removeValue(forKey: id)?.resume(returning: args)
        case .disconnect, .close:
            shutdown(reason: "server disconnect")
        case .pong:
            break
        }
    }

    private func startWatchdog() {
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                if await self.heartbeatExpired() {
                    await self.shutdown(reason: "heartbeat timeout")
                    return
                }
            }
        }
    }

    private func heartbeatExpired() -> Bool { ContinuousClock.now - lastHeartbeat > heartbeatDeadline }

    private func shutdown(reason: String) {
        guard !closed else { return }
        closed = true
        Self.log.info("socket closed: \(reason, privacy: .public)")
        watchdog?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        connectContinuation?.resume(throwing: ConnectError(message: reason))
        connectContinuation = nil
        for (_, continuation) in pendingAcks { continuation.resume(throwing: NotConnected()) }
        pendingAcks.removeAll()
        eventSink.yield(.disconnected(reason: reason))
        eventSink.finish()
    }
}

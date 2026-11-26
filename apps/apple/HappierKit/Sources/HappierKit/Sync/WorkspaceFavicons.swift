import CryptoKit
import Foundation
import Observation
import os

/// Each project's own icon (its favicon), drawn on its sessions in place of the agent's logo. The
/// computer that holds the folder finds it (`workspace.favicon.resolve`, the same lookup the web
/// app's list uses); it is asked once per folder per launch, and what it sent is kept on disk so
/// the list shows it at once on the next launch, before the computer answers.
@MainActor
@Observable
public final class WorkspaceFavicons {
    public struct Icon: Sendable, Equatable, Codable {
        public let data: Data
        public let mimeType: String

        public init(data: Data, mimeType: String) {
            self.data = data
            self.mimeType = mimeType
        }
    }

    public typealias RPC = @MainActor (_ machineId: String, _ method: String, _ params: JSONValue) async throws -> JSONValue

    /// The icons known so far, by folder (`key`).
    public private(set) var icons: [String: Icon] = [:]
    /// Turns what the computer sent into something this device can draw (an SVG on the iPhone,
    /// which has no SVG decoder); nil leaves the folder without an icon. Run only when what the
    /// computer sends changes.
    @ObservationIgnored public var prepare: @MainActor (Icon) async -> Icon? = { $0 }

    @ObservationIgnored private let rpc: RPC
    @ObservationIgnored private let directory: URL
    /// What the computer sent for each folder (a digest), so an unchanged icon isn't prepared again.
    @ObservationIgnored private var sources: [String: String] = [:]
    /// When each folder may be asked again: never within a launch once the computer answered;
    /// after a while when it couldn't be reached (offline, still connecting).
    @ObservationIgnored private var nextAsk: [String: Date] = [:]
    @ObservationIgnored private let retryDelay: TimeInterval
    private static let log = Logger(subsystem: "dev.happier.apple", category: "favicons")

    /// One folder's icon on disk.
    private struct Saved: Codable {
        let key: String
        let source: String
        let icon: Icon
    }

    public init(directory: URL, retryDelay: TimeInterval = 30, rpc: @escaping RPC) {
        self.directory = directory
        self.retryDelay = retryDelay
        self.rpc = rpc
        // A handful of small files, read before the list first draws.
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { continue }
            icons[saved.key] = saved.icon
            sources[saved.key] = saved.source
        }
    }

    /// The folder's icon if known, asking the computer for it when due. Safe to call from a view's
    /// body: what it learns arrives later through `icons`.
    public func icon(machineId: String?, path: String?) -> Icon? {
        guard let machineId, let path, !path.isEmpty else { return nil }
        let key = Self.key(machineId: machineId, path: path)
        if nextAsk[key].map({ $0 <= Date() }) ?? true {
            nextAsk[key] = .distantFuture
            Task { await self.ask(machineId: machineId, path: path) }
        }
        return icons[key]
    }

    /// Asks the computer for the folder's icon and keeps the answer (a found icon, or none).
    func ask(machineId: String, path: String) async {
        let key = Self.key(machineId: machineId, path: path)
        let response: JSONValue
        do {
            response = try await rpc(machineId, "workspace.favicon.resolve", ["workspacePath": .string(path)])
        } catch {
            // Unreachable for now: what's on disk stays, and a later look asks again.
            Self.log.notice("favicon lookup failed, retrying later: \(String(describing: error), privacy: .public)")
            nextAsk[key] = Date().addingTimeInterval(retryDelay)
            return
        }
        guard let sent = Self.icon(from: response) else {
            if response["success"]?.boolValue == true { forget(key) }
            return
        }
        let source = Self.digest(sent.data)
        if sources[key] == source, icons[key] != nil { return }
        guard let icon = await prepare(sent) else {
            forget(key)
            return
        }
        icons[key] = icon
        sources[key] = source
        save(Saved(key: key, source: source, icon: icon))
    }

    /// The icon in a `workspace.favicon.resolve` answer: nil when the folder has none, the
    /// computer refused, or the answer is malformed.
    static func icon(from response: JSONValue) -> Icon? {
        guard response["success"]?.boolValue == true, response["found"]?.boolValue == true,
              let mimeType = response["mimeType"]?.stringValue,
              let encoded = response["contentBase64"]?.stringValue,
              let data = Data(base64Encoded: encoded), !data.isEmpty else { return nil }
        return Icon(data: data, mimeType: mimeType)
    }

    static func key(machineId: String, path: String) -> String { machineId + "\u{0}" + path }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func file(_ key: String) -> URL {
        directory.appending(path: Self.digest(Data(key.utf8)) + ".json")
    }

    private func forget(_ key: String) {
        icons[key] = nil
        sources[key] = nil
        try? FileManager.default.removeItem(at: file(key))
    }

    private func save(_ saved: Saved) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: file(saved.key), options: .atomic)
        } catch {
            // Only the next launch's head start is lost.
            Self.log.error("favicon not kept on disk: \(String(describing: error), privacy: .public)")
        }
    }
}

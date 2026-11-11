import Foundation
import Observation

/// Downloads a Whisper model and readies it for this device (the network and Core ML).
public protocol WhisperModelDownloader: Sendable {
    /// Downloads `model` under `base`, reporting 0…1, and returns the folder holding its files.
    func download(_ model: WhisperModel, into base: URL, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> URL
    /// The first load compiles the model for this device, which can take minutes: done here, once,
    /// rather than on the first dictation.
    func prepare(_ folder: URL) async throws
}

/// The Whisper models on this device, downloaded from Settings › Dictation: kept in Application
/// Support so the system doesn't purge them, and never counted as installed until a download and
/// its preparation both finished. One of them is in use: the one chosen, else the latest
/// download, else the most accurate one left.
@MainActor
@Observable
public final class WhisperModelLibrary {
    public enum State: Equatable, Sendable {
        case absent
        case downloading(Double)
        /// Downloaded; compiling for this device.
        case preparing
        case installed(bytes: Int64)
        case failed(String)
    }

    private var states: [WhisperModel: State] = [:]
    /// The model chosen to dictate (or downloaded last); kept in `directory` across launches.
    private var chosen: WhisperModel?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let downloader: any WhisperModelDownloader
    @ObservationIgnored private var job: Task<URL, any Error>?

    /// Written last, next to the files: holds the model folder's path relative to the model's base.
    private static let marker = "installed"
    /// Holds the chosen model's id, in `directory`.
    private static let choice = "in-use"

    public init(directory: URL, downloader: any WhisperModelDownloader) {
        self.directory = directory
        self.downloader = downloader
        let files = FileManager.default
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        // Re-downloadable: kept out of device backups.
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var folder = directory
        try? folder.setResourceValues(excluded)
        for model in WhisperModel.allCases {
            if self.folder(of: model) != nil {
                states[model] = .installed(bytes: Self.size(of: base(of: model)))
            } else {
                // A download the app didn't live to finish.
                try? files.removeItem(at: base(of: model))
            }
        }
        chosen = (try? String(contentsOf: directory.appending(path: Self.choice), encoding: .utf8)).flatMap(WhisperModel.init(rawValue:))
    }

    public func state(of model: WhisperModel) -> State { states[model] ?? .absent }

    /// The model dictation uses, if one is installed.
    public var inUse: WhisperModel? {
        if let chosen, isInstalled(chosen) { return chosen }
        return installedModels.first
    }

    /// The models on this device, most accurate first.
    public var installedModels: [WhisperModel] { WhisperModel.allCases.filter(isInstalled) }

    /// Dictates with `model` from now on, if it is installed.
    public func use(_ model: WhisperModel) {
        guard isInstalled(model) else { return }
        chosen = model
        try? model.id.write(to: directory.appending(path: Self.choice), atomically: true, encoding: .utf8)
    }

    private func isInstalled(_ model: WhisperModel) -> Bool {
        if case .installed = state(of: model) { true } else { false }
    }

    /// A download or preparation is under way.
    public var isBusy: Bool { job != nil }

    /// Where an installed model's files are.
    public func folder(of model: WhisperModel) -> URL? {
        guard let relative = try? String(contentsOf: base(of: model).appending(path: Self.marker), encoding: .utf8) else { return nil }
        let folder = base(of: model).appending(path: relative)
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }

    /// Downloads and prepares `model`. Returns when it is installed, failed or was cancelled; a
    /// second download while one runs is ignored.
    public func download(_ model: WhisperModel) async {
        guard job == nil, !isInstalled(model) else { return }
        let base = base(of: model)
        try? FileManager.default.removeItem(at: base)
        states[model] = .downloading(0)
        let downloader = downloader
        let job = Task { [weak self] in
            let folder = try await downloader.download(model, into: base) { fraction in
                guard let self, case .downloading(let shown) = self.state(of: model), fraction > shown else { return }
                self.states[model] = .downloading(fraction)
            }
            try Task.checkCancellation()
            self?.states[model] = .preparing
            try await downloader.prepare(folder)
            try Task.checkCancellation()
            return folder
        }
        self.job = job
        defer { self.job = nil }
        do {
            let folder = try await job.value
            try Self.relativePath(of: folder, in: base).write(to: base.appending(path: Self.marker), atomically: true, encoding: .utf8)
            states[model] = .installed(bytes: Self.size(of: base))
            // Downloaded to dictate with it.
            use(model)
        } catch {
            try? FileManager.default.removeItem(at: base)
            states[model] = job.isCancelled || error is CancellationError ? .absent : .failed(error.localizedDescription)
        }
    }

    /// Stops the download or preparation under way and removes what it left.
    public func cancel() { job?.cancel() }

    /// Removes `model`. When it was in use, the most accurate model left takes over.
    public func delete(_ model: WhisperModel) {
        try? FileManager.default.removeItem(at: base(of: model))
        states[model] = .absent
        if chosen == model {
            chosen = nil
            try? FileManager.default.removeItem(at: directory.appending(path: Self.choice))
        }
    }

    private func base(of model: WhisperModel) -> URL { directory.appending(path: model.id, directoryHint: .isDirectory) }

    private static func relativePath(of folder: URL, in base: URL) -> String {
        let inner = folder.resolvingSymlinksInPath().pathComponents
        let outer = base.resolvingSymlinksInPath().pathComponents
        return inner.starts(with: outer) ? inner.dropFirst(outer.count).joined(separator: "/") : folder.path
    }

    /// What the model takes on disk (what deleting it frees), not counting the marker.
    private static func size(of base: URL) -> Int64 {
        let marker = base.appending(path: marker).standardizedFileURL.path
        let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let file = files?.nextObject() as? URL {
            guard file.standardizedFileURL.path != marker else { continue }
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

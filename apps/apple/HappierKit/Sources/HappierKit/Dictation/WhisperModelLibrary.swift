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

/// The Whisper model on this device, downloaded from Settings › Dictation: kept in Application
/// Support so the system doesn't purge it, and never counted as installed until its download and
/// preparation both finished.
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
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let downloader: any WhisperModelDownloader
    @ObservationIgnored private var job: Task<URL, any Error>?

    /// Written last, next to the files: holds the model folder's path relative to the model's base.
    private static let marker = "installed"

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
    }

    public func state(of model: WhisperModel) -> State { states[model] ?? .absent }

    /// The model dictation uses, if one is installed.
    public var installed: WhisperModel? {
        WhisperModel.allCases.first { if case .installed = state(of: $0) { true } else { false } }
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
        guard job == nil, installed != model else { return }
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
        } catch {
            try? FileManager.default.removeItem(at: base)
            states[model] = job.isCancelled || error is CancellationError ? .absent : .failed(error.localizedDescription)
        }
    }

    /// Stops the download or preparation under way and removes what it left.
    public func cancel() { job?.cancel() }

    public func delete(_ model: WhisperModel) {
        try? FileManager.default.removeItem(at: base(of: model))
        states[model] = .absent
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

import Foundation
import Testing
@testable import HappierKit

/// The Whisper model downloaded from Settings › Dictation: progress, kept on disk across launches,
/// never half-installed, deletable, one download at a time.
@MainActor
struct WhisperModelLibraryTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "whisper-tests-\(UUID().uuidString)")

    /// Network boundary: writes the files a real download would, reporting progress, or fails.
    private final class FakeDownloader: WhisperModelDownloader, @unchecked Sendable {
        var failure: (any Error)?
        var prepareFailure: (any Error)?
        var bytes = 1_000
        /// Called after the first progress report, while the download is still "running".
        var midway: (@MainActor () async -> Void)?

        func download(_ model: WhisperModel, into base: URL, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> URL {
            let folder = base.appending(path: "models/argmaxinc/whisperkit-coreml/\(model.id)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(count: bytes / 2).write(to: folder.appending(path: "AudioEncoder.bin"))
            await progress(0.5)
            if let midway { await midway() }
            try Task.checkCancellation()
            if let failure { throw failure }
            try Data(count: bytes - bytes / 2).write(to: folder.appending(path: "TextDecoder.bin"))
            await progress(1)
            return folder
        }

        func prepare(_ folder: URL) async throws {
            if let prepareFailure { throw prepareFailure }
        }
    }

    private struct Offline: LocalizedError { var errorDescription: String? { "The Internet connection appears to be offline." } }

    private func files(of model: WhisperModel) -> Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: model.id).path)
    }

    @Test func downloadsWithProgressAndStaysInstalledAcrossLaunches() async {
        let downloader = FakeDownloader()
        let library = WhisperModelLibrary(directory: directory, downloader: downloader)
        #expect(library.state(of: .largeV3Turbo) == .absent)
        var seen: [WhisperModelLibrary.State] = []
        downloader.midway = { seen.append(library.state(of: .largeV3Turbo)) }

        await library.download(.largeV3Turbo)

        #expect(seen == [.downloading(0.5)])
        #expect(library.state(of: .largeV3Turbo) == .installed(bytes: 1_000))
        #expect(library.inUse == .largeV3Turbo)
        let relaunched = WhisperModelLibrary(directory: directory, downloader: downloader)
        #expect(relaunched.inUse == .largeV3Turbo)
        #expect(relaunched.folder(of: .largeV3Turbo)?.lastPathComponent == WhisperModel.largeV3Turbo.id)
    }

    @Test func aFailedDownloadLeavesNothingBehind() async {
        let downloader = FakeDownloader()
        downloader.failure = Offline()
        let library = WhisperModelLibrary(directory: directory, downloader: downloader)

        await library.download(.largeV3Turbo)

        #expect(library.state(of: .largeV3Turbo) == .failed("The Internet connection appears to be offline."))
        #expect(library.inUse == nil)
        #expect(!files(of: .largeV3Turbo))
    }

    @Test func aModelThatCannotBePreparedIsNotInstalled() async {
        let downloader = FakeDownloader()
        downloader.prepareFailure = Offline()
        let library = WhisperModelLibrary(directory: directory, downloader: downloader)

        await library.download(.largeV3Turbo)

        #expect(library.state(of: .largeV3Turbo) == .failed("The Internet connection appears to be offline."))
        #expect(library.inUse == nil)
        #expect(!files(of: .largeV3Turbo))
    }

    @Test func aDownloadCutShortIsNotInstalledOnTheNextLaunch() async throws {
        // The app was killed mid-download: files are there, the download never finished.
        let partial = directory.appending(path: "\(WhisperModel.largeV3Turbo.id)/models/argmaxinc/whisperkit-coreml/x")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data(count: 10).write(to: partial.appending(path: "AudioEncoder.bin"))

        let library = WhisperModelLibrary(directory: directory, downloader: FakeDownloader())

        #expect(library.state(of: .largeV3Turbo) == .absent)
        #expect(library.inUse == nil)
        #expect(!files(of: .largeV3Turbo))
    }

    @Test func cancellingStopsAndCleansUp() async {
        let downloader = FakeDownloader()
        let library = WhisperModelLibrary(directory: directory, downloader: downloader)
        var cancelledMidway = false
        downloader.midway = {
            #expect(files(of: .largeV3Turbo))
            library.cancel()
            cancelledMidway = true
        }

        await library.download(.largeV3Turbo)

        #expect(cancelledMidway)
        #expect(library.state(of: .largeV3Turbo) == .absent)
        #expect(!files(of: .largeV3Turbo))
    }

    @Test func deletingRemovesTheModel() async {
        let library = WhisperModelLibrary(directory: directory, downloader: FakeDownloader())
        await library.download(.largeV3Turbo)
        #expect(library.inUse == .largeV3Turbo)

        library.delete(.largeV3Turbo)

        #expect(library.state(of: .largeV3Turbo) == .absent)
        #expect(library.inUse == nil)
        #expect(!files(of: .largeV3Turbo))
    }

    @Test func oneDownloadAtATime() async {
        let downloader = FakeDownloader()
        let library = WhisperModelLibrary(directory: directory, downloader: downloader)
        downloader.midway = {
            downloader.midway = nil
            await library.download(.largeV3Turbo)
            #expect(library.state(of: .largeV3Turbo) == .downloading(0.5))
        }

        await library.download(.largeV3Turbo)

        #expect(library.inUse == .largeV3Turbo)
    }

    // MARK: Several models, one in use

    @Test func theLatestDownloadIsTheOneInUse() async {
        let library = WhisperModelLibrary(directory: directory, downloader: FakeDownloader())
        await library.download(.largeV3Turbo)
        #expect(library.inUse == .largeV3Turbo)

        // A lighter one downloaded as an alternative: it is what you downloaded it for.
        await library.download(.tiny)

        #expect(library.inUse == .tiny)
        // Both stay on the device, most accurate first.
        #expect(library.installedModels == [.largeV3Turbo, .tiny])
    }

    @Test func choosingADownloadedModelPutsItInUseAcrossLaunches() async {
        let downloader = FakeDownloader()
        let library = WhisperModelLibrary(directory: directory, downloader: downloader)
        await library.download(.tiny)
        await library.download(.largeV3Turbo)

        library.use(.tiny)

        #expect(library.inUse == .tiny)
        #expect(WhisperModelLibrary(directory: directory, downloader: downloader).inUse == .tiny)
    }

    @Test func onlyADownloadedModelCanBeChosen() async {
        let library = WhisperModelLibrary(directory: directory, downloader: FakeDownloader())
        await library.download(.base)

        library.use(.small)

        #expect(library.inUse == .base)
    }

    @Test func deletingTheModelInUseFallsBackToAnotherDownloadedOne() async {
        let library = WhisperModelLibrary(directory: directory, downloader: FakeDownloader())
        await library.download(.tiny)
        await library.download(.small)
        await library.download(.largeV3Turbo)
        library.use(.tiny)

        // Another model goes: the one in use stays.
        library.delete(.small)
        #expect(library.inUse == .tiny)

        // The one in use goes: the most accurate one left takes over; none left, Apple's engine.
        library.delete(.tiny)
        #expect(library.inUse == .largeV3Turbo)
        library.delete(.largeV3Turbo)
        #expect(library.inUse == nil)
    }

    @Test func aChosenModelThatIsGoneFallsBackOnTheNextLaunch() async throws {
        let downloader = FakeDownloader()
        let library = WhisperModelLibrary(directory: directory, downloader: downloader)
        await library.download(.base)
        await library.download(.tiny)
        // Its files went away while the app wasn't running (an interrupted delete).
        try FileManager.default.removeItem(at: directory.appending(path: WhisperModel.tiny.id))

        #expect(WhisperModelLibrary(directory: directory, downloader: downloader).inUse == .base)
    }
}

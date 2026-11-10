import AVFoundation
import HappierKit
import os
@preconcurrency import WhisperKit
#if os(iOS)
import UIKit
#endif

/// The Whisper model on this device and how it is downloaded (Settings › Dictation).
@MainActor
enum WhisperModels {
    /// Application Support: the system doesn't purge it to free space (Caches it would).
    static let library = WhisperModelLibrary(
        directory: URL.applicationSupportDirectory.appending(path: "Dictation/Whisper", directoryHint: .isDirectory),
        downloader: WhisperKitDownloader())

    /// The models WhisperKit's table (bundled, no network) lists for this device.
    nonisolated static let deviceSupports: [String] = WhisperKit.recommendedModels().supported
}

/// Downloads from Argmax's Hugging Face repository and compiles the model for this device.
struct WhisperKitDownloader: WhisperModelDownloader {
    func download(_ model: WhisperModel, into base: URL, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> URL {
        try await WhisperKit.download(variant: model.variant, downloadBase: base) { report in
            let fraction = report.fractionCompleted
            Task { @MainActor in progress(fraction) }
        }
    }

    func prepare(_ folder: URL) async throws {
        try await WhisperRuntime.shared.prepare(folder)
    }
}

/// The loaded Whisper model, shared by every take. One load or transcription at a time (WhisperKit
/// isn't made for concurrent calls on one instance). Loading takes about a second once the model
/// has been compiled for the device; it is let go when the app leaves the screen (iPhone, iPad) or
/// memory runs low.
actor WhisperRuntime {
    static let shared = WhisperRuntime()
    private static let log = Logger(subsystem: "dev.happier.apple", category: "dictation")

    private var kit: WhisperKit?
    private var folder: URL?
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private init() {
        #if os(iOS)
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.didReceiveMemoryWarningNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                Task { await WhisperRuntime.shared.unload() }
            }
        }
        #endif
    }

    /// Compiles the downloaded model for this device (minutes, the first time) and keeps it loaded.
    func prepare(_ folder: URL) async throws {
        await acquire()
        defer { release() }
        _ = try await loaded(folder, prewarm: true)
    }

    func transcribe(_ audio: [Float], options: DecodingOptions, folder: URL) async throws -> [WhisperStreamTranscript.Segment] {
        await acquire()
        defer { release() }
        let kit = try await loaded(folder, prewarm: false)
        let results = try await kit.transcribe(audioArray: audio, decodeOptions: options)
        return results.flatMap(\.segments).map { .init(text: $0.text, start: $0.start, end: $0.end) }
    }

    func unload() async {
        await acquire()
        defer { release() }
        guard let kit else { return }
        await kit.unloadModels()
        self.kit = nil
        folder = nil
        Self.log.notice("whisper unloaded")
    }

    private func loaded(_ folder: URL, prewarm: Bool) async throws -> WhisperKit {
        if let kit, self.folder == folder { return kit }
        if let kit { await kit.unloadModels() }
        kit = nil
        let started = ContinuousClock.now
        // The tokenizer is fetched once into the model's own folder (while preparing), so later
        // loads work offline and deleting the model removes it too.
        let config = WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: folder, verbose: false, logLevel: .error,
                                      prewarm: prewarm, load: true, download: false)
        let loaded = try await WhisperKit(config)
        kit = loaded
        self.folder = folder
        Self.log.notice("whisper loaded in \(started.duration(to: .now), privacy: .public)")
        return loaded
    }

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}

/// Whisper on the device, live: about once a second it transcribes the take so far from the last
/// confirmed segment (WhisperKit's own streaming approach), so the text appears in pieces while
/// speaking; letting go transcribes the rest.
final class WhisperRecognizer: DictationRecognizer, @unchecked Sendable {
    private static let log = Logger(subsystem: "dev.happier.apple", category: "dictation")
    private static let sampleRate = Double(WhisperKit.sampleRate)
    private static let frameSamples = Int(DictationSpeech.frameSeconds * Double(WhisperKit.sampleRate))

    private let converter = DictationAudioConverter(
        to: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(WhisperKit.sampleRate), channels: 1, interleaved: false)!)
    private let lock = NSLock()
    /// 16 kHz mono, the whole take.
    private var samples: [Float] = []
    /// Loudness of each whole 100 ms frame of `samples`.
    private var levels: [Float] = []
    private var ended = false
    private var loop: Task<String, Never>?

    init(folder: URL, language: String, update: @escaping DictationUpdate) {
        loop = Task.detached(priority: .userInitiated) { [self] in
            await run(folder: folder, language: language, update: update)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer), let channel = converted.floatChannelData?[0] else { return }
        let new = UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))
        lock.withLock {
            samples.append(contentsOf: new)
            while (levels.count + 1) * Self.frameSamples <= samples.count {
                let start = levels.count * Self.frameSamples
                levels.append(DictationSpeech.level(of: samples[start..<start + Self.frameSamples]))
            }
        }
    }

    func finish() async -> String {
        lock.withLock { ended = true }
        return await loop?.value ?? ""
    }

    func cancel() {
        lock.withLock { ended = true }
        loop?.cancel()
    }

    private func run(folder: URL, language: String, update: DictationUpdate) async -> String {
        var transcript = WhisperStreamTranscript()
        var options = DecodingOptions(task: .transcribe, language: language, temperature: 0, usePrefillPrompt: true,
                                      detectLanguage: false, skipSpecialTokens: true)
        var transcribed = 0
        do {
            while !Task.isCancelled {
                // Counts only: holding the samples here would make every microphone buffer copy them all.
                let (count, levels, ended) = lock.withLock { (samples.count, self.levels, self.ended) }
                // About a second of new audio per pass while speaking; everything once it ends.
                if !ended, Double(count - transcribed) < Self.sampleRate {
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }
                transcribed = count
                // Only up to the end of the speech: Whisper writes words for silence.
                guard let frames = DictationSpeech.speechEnd(frameLevels: levels),
                      Float(frames * Self.frameSamples) / Float(Self.sampleRate) > transcript.confirmedEnd else {
                    if ended { break } else { continue }
                }
                options.clipTimestamps = [transcript.confirmedEnd]
                let speech = lock.withLock { Array(samples.prefix(frames * Self.frameSamples)) }
                let started = ContinuousClock.now
                let segments = try await WhisperRuntime.shared.transcribe(speech, options: options, folder: folder)
                try Task.checkCancellation()
                transcript.update(segments, final: ended)
                Self.log.debug("whisper pass \(speech.count / Self.frameSamples) frames in \(started.duration(to: .now), privacy: .public)")
                if ended { break }
                update(transcript.text, false, nil)
            }
        } catch is CancellationError {
            return transcript.text
        } catch {
            Self.log.error("whisper failed: \(String(describing: error), privacy: .public)")
            update(transcript.text, true, error)
            return transcript.text
        }
        update(transcript.text, true, nil)
        return transcript.text
    }
}

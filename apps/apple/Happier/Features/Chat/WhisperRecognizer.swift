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

/// The loaded Whisper model, shared by every take. One transcription at a time (WhisperKit isn't
/// made for concurrent calls on one instance). A take doesn't wait for it to load (a second or so,
/// minutes when the system compiles it again): Apple's engine dictates that take while it loads
/// (`DictationEngine.forTake`). It is let go when the app leaves the screen (iPhone, iPad) and
/// loads again when the app is back; on low memory it is let go until the next dictation asks.
actor WhisperRuntime {
    static let shared = WhisperRuntime()
    private static let log = Logger(subsystem: "dev.happier.apple", category: "dictation")

    /// The model isn't in memory (and the take doesn't wait for it).
    struct NotLoaded: Error {}

    private var kit: WhisperKit?
    private var folder: URL?
    /// The one load in progress: every caller that needs the model waits for this one.
    private var loading: (folder: URL, task: Task<Void, any Error>)?
    /// In memory when the app left the screen: loaded again when the app is back.
    private var reloadOnReturn: URL?
    private var onScreen = true
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private init() {
        #if os(iOS)
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
            Task { await WhisperRuntime.shared.leftScreen() }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in
            Task { await WhisperRuntime.shared.returned() }
        }
        center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in
            Task { await WhisperRuntime.shared.unload(.lowMemory) }
        }
        #endif
    }

    func isLoaded(_ folder: URL) -> Bool { kit != nil && self.folder == folder }

    /// Loads `folder`'s model in the background, unless it is in memory or loading already.
    func warmUp(_ folder: URL) {
        guard !isLoaded(folder) else { return }
        _ = load(folder, prewarm: false)
    }

    /// Compiles the downloaded model for this device (minutes, the first time) and keeps it loaded.
    func prepare(_ folder: URL) async throws {
        guard !isLoaded(folder) else { return }
        try await load(folder, prewarm: true).value
    }

    /// Transcribes with the model in memory. Without it, `waitForLoad` loads it first; otherwise it
    /// throws `NotLoaded` (the next take loads it: after low memory, not at once).
    func transcribe(_ audio: [Float], options: DecodingOptions, folder: URL, waitForLoad: Bool,
                    callback: TranscriptionCallback? = nil) async throws -> [WhisperStreamTranscript.Segment] {
        if !isLoaded(folder) {
            guard waitForLoad else { throw NotLoaded() }
            try await load(folder, prewarm: false).value
        }
        await acquire()
        defer { release() }
        // Given up while it waited its turn (the take ended, or ran out of time).
        try Task.checkCancellation()
        // Let go meanwhile (the app left the screen, low memory).
        guard let kit, isLoaded(folder) else { throw NotLoaded() }
        let results = try await kit.transcribe(audioArray: audio, decodeOptions: options, callback: callback)
        return results.flatMap(\.segments).map { .init(text: $0.text, start: $0.start, end: $0.end) }
    }

    /// Lets the model go (`only` that folder's, when given).
    func unload(_ reason: WhisperModelStatus.Unload, only: URL? = nil) async {
        if let only, only != folder, only != reloadOnReturn { return }
        if reason != .background { reloadOnReturn = nil }
        await acquire()
        defer { release() }
        guard let kit, only == nil || only == folder else { return }
        await kit.unloadModels()
        self.kit = nil
        folder = nil
        Self.log.notice("whisper unloaded: \(reason.rawValue, privacy: .public)")
        await Self.report { status in
            status.phase = .notLoaded
            status.since = .now
            status.unloaded = reason
        }
    }

    private func leftScreen() async {
        onScreen = false
        reloadOnReturn = folder ?? loading?.folder
        await unload(.background)
    }

    private func returned() {
        onScreen = true
        guard let folder = reloadOnReturn else { return }
        reloadOnReturn = nil
        warmUp(folder)
    }

    /// The load of `folder` in progress, or a new one. When the app left the screen meanwhile the
    /// model is let go again (it loads when the app is back).
    private func load(_ folder: URL, prewarm: Bool) -> Task<Void, any Error> {
        if let loading, loading.folder == folder { return loading.task }
        let task = Task<Void, any Error> {
            defer { loading = nil }
            // Another model is let go first: two in memory at once is a model too many.
            if let kit, self.folder != folder {
                await acquire()
                await kit.unloadModels()
                self.kit = nil
                self.folder = nil
                release()
            }
            let started = ContinuousClock.now
            let model = WhisperModel(rawValue: folder.lastPathComponent)
            await Self.report { status in
                status.phase = .loading
                status.model = model
                status.since = .now
                status.unloaded = nil
                status.failure = nil
            }
            do {
                // The tokenizer is fetched once into the model's own folder (while preparing), so
                // later loads work offline and deleting the model removes it too.
                let config = WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: folder, verbose: false, logLevel: .error,
                                              prewarm: prewarm, load: true, download: false)
                let loaded = try await WhisperKit(config)
                let took = started.duration(to: .now)
                Self.log.notice("whisper loaded in \(took, privacy: .public)")
                guard onScreen else {
                    await loaded.unloadModels()
                    reloadOnReturn = folder
                    await Self.report { status in
                        status.phase = .notLoaded
                        status.since = .now
                        status.unloaded = .background
                        status.lastLoadSeconds = took.seconds
                    }
                    return
                }
                kit = loaded
                self.folder = folder
                await Self.report { status in
                    status.phase = .loaded
                    status.since = .now
                    status.lastLoadSeconds = took.seconds
                }
            } catch {
                Self.log.error("whisper load failed: \(String(describing: error), privacy: .public)")
                await Self.report { status in
                    status.phase = .failed
                    status.since = .now
                    status.failure = error.localizedDescription
                }
                throw error
            }
        }
        loading = (folder, task)
        return task
    }

    private static func report(_ change: @escaping @Sendable (inout WhisperModelStatus) -> Void) async {
        await MainActor.run { DictationDiagnostics.shared.whisper(change) }
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
/// speaking; letting go transcribes the rest. When Whisper can't keep the take (its model was let
/// go, it failed, or it had no words in the composer by `firstTextDeadline`), Apple's engine takes
/// it over with all its audio so far, so the words still come.
final class WhisperRecognizer: DictationRecognizer, @unchecked Sendable {
    /// Starts Apple's engine for a take handed over: the engine, and its recognizer.
    typealias Handover = @Sendable (@escaping DictationUpdate) async throws -> (DictationEngine, any DictationRecognizer)

    /// How long Whisper has, from its first pass over speech, to put words in the composer. On a
    /// Mac mini the first words came ~0.9 s into that pass (1.9 s after listening); a take with none
    /// 3 s in is stuck (a model loading or compiling, the Neural Engine busy), and Apple's engine,
    /// given the same audio, writes it instead.
    static let firstTextDeadline: Duration = .seconds(3)

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
    private var cancelled = false
    /// Apple's engine, once the take was handed over to it: it hears the rest of the take.
    private var apple: (any DictationRecognizer)?
    private let handover: Handover?
    private let takeLog: DictationTakeLog
    private let update: DictationUpdate
    private var loop: Task<String, Never>?

    /// Without `handover` (speech recognition not allowed) Whisper keeps the take whatever happens,
    /// waiting for its model if it must.
    init(folder: URL, language: String, handover: Handover?, log: DictationTakeLog, update: @escaping DictationUpdate) {
        self.handover = handover
        takeLog = log
        self.update = update
        loop = Task.detached(priority: .userInitiated) { [self] in
            await run(folder: folder, language: language)
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
            // Handed over: Apple's engine hears it after the audio it was given, in order.
            apple?.append(converted)
        }
    }

    func finish() async -> String {
        lock.withLock { ended = true }
        let text = await loop?.value ?? ""
        if let apple = lock.withLock({ apple }) { return await apple.finish() }
        return text
    }

    func cancel() {
        let apple = lock.withLock {
            ended = true
            cancelled = true
            return self.apple
        }
        loop?.cancel()
        apple?.cancel()
    }

    private func run(folder: URL, language: String) async -> String {
        var transcript = WhisperStreamTranscript()
        // The final pass is what gets sent: WhisperKit's fallback decodes it again at rising
        // temperatures when it isn't sure. A live pass is a draft the next one replaces: one decode,
        // stopped once it starts repeating itself (as WhisperKit's AudioStreamTranscriber does);
        // with the fallback a pass could decode up to 6 times, seconds on an iPhone, each time
        // with different words.
        let last = DecodingOptions(task: .transcribe, language: language, temperature: 0, usePrefillPrompt: true,
                                   detectLanguage: false, skipSpecialTokens: true)
        var live = last
        live.temperatureFallbackCount = 0
        let stopRepeating = Self.stopRepeating(threshold: live.compressionRatioThreshold)
        var transcribed = 0
        var deadline: ContinuousClock.Instant?
        var shown = false
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
                takeLog.heard(frameLevels: levels)
                // Only up to the end of the speech: Whisper writes words for silence.
                guard let frames = DictationSpeech.speechEnd(frameLevels: levels),
                      let pass = transcript.pass(speechEnd: Float(frames * Self.frameSamples) / Float(Self.sampleRate),
                                                 minimumLength: live.windowClipTime) else {
                    if ended { break } else { continue }
                }
                var options = ended ? last : live
                options.clipTimestamps = [pass.start]
                var audio = lock.withLock { Array(samples.prefix(frames * Self.frameSamples)) }
                // A take too short to decode is read with silence after it.
                let length = Int((Double(pass.end) * Self.sampleRate).rounded(.up))
                if audio.count < length { audio += repeatElement(Float(0), count: length - audio.count) }
                if handover != nil, !shown, deadline == nil { deadline = .now + Self.firstTextDeadline }
                let started = ContinuousClock.now
                let segments = try await Self.within(shown ? nil : deadline) { [audio, options] in
                    try await WhisperRuntime.shared.transcribe(audio, options: options, folder: folder, waitForLoad: self.handover == nil,
                                                               callback: ended ? nil : stopRepeating)
                }
                try Task.checkCancellation()
                let took = started.duration(to: .now)
                takeLog.pass(seconds: took.seconds)
                transcript.update(segments, final: ended)
                Self.log.debug("whisper pass \(audio.count / Self.frameSamples) frames in \(took, privacy: .public)")
                if ended { break }
                shown = shown || !transcript.text.isEmpty
                update(transcript.text, false, nil)
            }
        } catch is CancellationError {
            return transcript.text
        } catch {
            let reason: DictationFallback = switch error {
            case is TooSlow: .whisperTooSlow
            case is WhisperRuntime.NotLoaded: .whisperNotLoaded
            default: .whisperFailed
            }
            Self.log.error("whisper gave up (\(reason.rawValue, privacy: .public)): \(String(describing: error), privacy: .public)")
            if await handOver(because: reason) { return transcript.text }
            update(transcript.text, true, error)
            return transcript.text
        }
        update(transcript.text, true, nil)
        return transcript.text
    }

    /// Apple's engine takes the take over: it is given the take's audio so far, then the rest as it
    /// comes. False when it can't start (the take then ends with Whisper's error).
    private func handOver(because reason: DictationFallback) async -> Bool {
        guard let handover, !lock.withLock({ cancelled }) else { return false }
        let update = update
        do {
            let (engine, recognizer) = try await handover { text, ended, failure in
                // Until Apple's engine has words of its own, the composer keeps what it shows.
                guard ended || failure != nil || !text.isEmpty else { return }
                update(text, ended, failure)
            }
            let format = converter.format
            let started = lock.withLock {
                guard !cancelled else { return false }
                var start = 0
                while start < samples.count {
                    let end = min(start + Int(Self.sampleRate), samples.count)
                    if let buffer = Self.buffer(samples[start..<end], format: format) { recognizer.append(buffer) }
                    start = end
                }
                apple = recognizer
                return true
            }
            guard started else {
                recognizer.cancel()
                return false
            }
            takeLog.handedOver(to: engine, because: reason)
            Self.log.notice("dictation handed to \(String(describing: engine), privacy: .public): \(reason.rawValue, privacy: .public)")
            return true
        } catch {
            Self.log.error("dictation handover failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Whisper had no words by its deadline.
    struct TooSlow: Error {}

    /// `work`, unless `deadline` comes first: then `TooSlow` at once, and the work is cancelled.
    /// The take doesn't wait for the cancelled work to wind down (a stalled Neural Engine call
    /// notices late), so Apple's engine takes it over on time.
    private static func within<T: Sendable>(_ deadline: ContinuousClock.Instant?,
                                            _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        guard let deadline else { return try await work() }
        let first = FirstResult<T>()
        let worker = Task {
            do { first.resume(with: .success(try await work())) } catch { first.resume(with: .failure(error)) }
        }
        let timer = Task {
            try await Task.sleep(until: deadline, clock: .continuous)
            first.resume(with: .failure(TooSlow()))
        }
        defer {
            worker.cancel()
            timer.cancel()
        }
        return try await withTaskCancellationHandler {
            try await first.value()
        } onCancel: {
            first.resume(with: .failure(CancellationError()))
        }
    }

    /// Stops a live pass whose last tokens repeat themselves (WhisperKit's AudioStreamTranscriber).
    private static func stopRepeating(threshold: Float?) -> TranscriptionCallback {
        { progress in
            let window = 60
            guard let threshold, progress.tokens.count > window,
                  TextUtilities.compressionRatio(of: Array(progress.tokens.suffix(window))) > threshold else { return nil }
            return false
        }
    }

    private static func buffer(_ samples: ArraySlice<Float>, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}

/// The first of several results, for whoever waits on it.
private final class FirstResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, any Error>?
    private var waiter: CheckedContinuation<T, any Error>?

    func resume(with result: Result<T, any Error>) {
        let waiter: CheckedContinuation<T, any Error>? = lock.withLock {
            guard self.result == nil else { return nil }
            self.result = result
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(with: result)
    }

    func value() async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<T, any Error>? = lock.withLock {
                if let result { return result }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

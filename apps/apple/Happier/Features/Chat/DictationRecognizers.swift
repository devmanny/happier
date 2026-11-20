import AVFoundation
import HappierKit
import os
import Speech

/// The take's whole text so far; `ended` when the engine ended the take on its own (an error, or
/// the recognizer's own end), with the error if there was one.
typealias DictationUpdate = @Sendable (_ text: String, _ ended: Bool, _ failure: (any Error)?) -> Void

/// One take's speech recognition. `Dictation` owns the microphone, the take and the composer's
/// text; an engine only turns the take's audio into its text.
protocol DictationRecognizer: AnyObject, Sendable {
    /// Each microphone buffer, on the audio thread.
    func append(_ buffer: AVAudioPCMBuffer)
    /// No more audio: returns the take's final text once the last words are in (or the engine gave
    /// up waiting for them).
    func finish() async -> String
    /// Stops at once; nothing more is delivered.
    func cancel()
}

enum DictationRecognizers {
    private static let log = Logger(subsystem: "dev.happier.apple", category: "dictation")

    /// The engine dictation uses on this device (the one Settings › Dictation shows).
    @MainActor
    static func engine(language: String?) async -> DictationEngine {
        await DictationEngine.choose(inUse: WhisperModels.library.inUse, deviceSupports: WhisperModels.deviceSupports) { @Sendable in
            await SpeechTranscriberRecognizer.isReady(for: language)
        }
    }

    /// Speech recognition is allowed already: Apple's engine can take a take without asking.
    nonisolated static var appleAllowed: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

    /// The engine this take starts with: Whisper once its model is in memory; until then Apple's,
    /// while Whisper loads for the next take.
    @MainActor
    static func take(language: String?) async -> DictationTake {
        let configured = await engine(language: language)
        var loaded = true
        if case .whisper(let model) = configured, let folder = WhisperModels.library.folder(of: model) {
            loaded = await WhisperRuntime.shared.isLoaded(folder)
            if !loaded { await WhisperRuntime.shared.warmUp(folder) }
        }
        return await DictationEngine.forTake(configured, whisperLoaded: loaded, appleAllowed: appleAllowed) { @Sendable in
            await SpeechTranscriberRecognizer.isReady(for: language)
        }
    }

    /// Starts recognizing a take with `engine`, in `language` (`SpeechLanguage.dictationLocale`).
    @MainActor
    static func start(_ engine: DictationEngine, language: String?, takeLog: DictationTakeLog,
                      update: @escaping DictationUpdate) async throws -> any DictationRecognizer {
        guard case .whisper(let model) = engine else { return try await startApple(engine, language: language, update: update) }
        guard let folder = WhisperModels.library.folder(of: model) else { throw DictationError.modelMissing }
        // Whisper gets the language fixed, never detected: the dictation language, else the user's first.
        let code = SpeechLanguage.languageCode(language ?? Locale.preferredLanguages.first ?? "en")
        Self.log.notice("dictation engine: whisper \(model.id, privacy: .public) language \(code, privacy: .public)")
        // Apple's engine takes the take over when Whisper can't keep it (speech recognition allowed).
        var handover: WhisperRecognizer.Handover?
        if appleAllowed {
            handover = { @Sendable update in
                let apple = await DictationEngine.apple { @Sendable in await SpeechTranscriberRecognizer.isReady(for: language) }
                let recognizer = try await startApple(apple, language: language, update: update)
                return (apple, recognizer)
            }
        }
        return WhisperRecognizer(folder: folder, language: code, handover: handover, log: takeLog, update: update)
    }

    nonisolated private static func startApple(_ engine: DictationEngine, language: String?, update: @escaping DictationUpdate) async throws -> any DictationRecognizer {
        switch engine {
        case .whisper, .speechTranscriber:
            log.notice("dictation engine: SpeechTranscriber \(language ?? "-", privacy: .public)")
            return try await SpeechTranscriberRecognizer.start(language: language ?? "en", update: update)
        case .speechRecognizer:
            guard let recognizer = language.flatMap({ SFSpeechRecognizer(locale: Locale(identifier: $0)) }) ?? SFSpeechRecognizer(),
                  recognizer.isAvailable else { throw DictationError.recognizerUnavailable }
            log.notice("dictation engine: SFSpeechRecognizer \(language ?? "-", privacy: .public)")
            return SpeechRecognizerRecognizer(recognizer: recognizer, update: update)
        }
    }
}

/// The older recognizer (SFSpeechRecognizer), on the device when it has the language.
final class SpeechRecognizerRecognizer: DictationRecognizer, @unchecked Sendable {
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    /// After a pause the recognizer reports only the new words; this keeps the earlier ones.
    private var transcript = DictationTranscript()
    private var done = false
    private var waiting: CheckedContinuation<Void, Never>?

    init(recognizer: SFSpeechRecognizer, update: @escaping DictationUpdate) {
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        // Speech calls this on its own queue.
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            // Metadata arrives with the last result of an utterance, when the speaker pauses.
            let finished = error != nil || (result?.isFinal ?? false)
            let text = lock.withLock {
                if let text = result?.bestTranscription.formattedString {
                    transcript.update(text, endsUtterance: result?.speechRecognitionMetadata != nil)
                }
                if finished { done = true }
                return transcript.text
            }
            update(text, finished, nil)
            if finished { resumeWaiting() }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }

    /// The recognizer still delivers what it was working on after the audio ends: up to a second
    /// and a half (push to talk sends right after).
    func finish() async -> String {
        request.endAudio()
        await withCheckedContinuation { continuation in
            let already = lock.withLock {
                if done { return true }
                waiting = continuation
                return false
            }
            if already { continuation.resume() }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                self?.resumeWaiting()
            }
        }
        return lock.withLock { transcript.text }
    }

    func cancel() {
        request.endAudio()
        task?.finish()
        resumeWaiting()
    }

    private func resumeWaiting() {
        let continuation = lock.withLock {
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume()
    }
}

/// Apple's SpeechAnalyzer (iOS/macOS 26): live results while speaking, finalized after pauses.
final class SpeechTranscriberRecognizer: DictationRecognizer, @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let converter: DictationAudioConverter
    private var results: Task<String, Never>?

    /// Languages whose download was asked for in this launch.
    private static let installing = OSAllocatedUnfairLock(initialState: Set<String>())

    /// SpeechAnalyzer can transcribe `language` on this device now. If the device supports it but
    /// the language isn't downloaded yet, the system download starts for next time.
    static func isReady(for language: String?) async -> Bool {
        guard SpeechTranscriber.isAvailable, let language,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else { return false }
        let id = locale.identifier(.bcp47)
        if await SpeechTranscriber.installedLocales.contains(where: { $0.identifier(.bcp47) == id }) { return true }
        if installing.withLock({ $0.insert(id).inserted }) {
            Task.detached(priority: .utility) {
                let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
                try? await AssetInventory.assetInstallationRequest(supporting: [module])?.downloadAndInstall()
            }
        }
        return false
    }

    static func start(language: String, update: @escaping DictationUpdate) async throws -> SpeechTranscriberRecognizer {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw DictationError.recognizerUnavailable
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw DictationError.recognizerUnavailable
        }
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: stream)
        return SpeechTranscriberRecognizer(analyzer: analyzer, transcriber: transcriber, input: input, format: format, update: update)
    }

    private init(analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber, input: AsyncStream<AnalyzerInput>.Continuation,
                 format: AVAudioFormat, update: @escaping DictationUpdate) {
        self.analyzer = analyzer
        self.input = input
        converter = DictationAudioConverter(to: format)
        results = Task {
            // Finalized text, then the latest guess at what follows it.
            var finalized = ""
            var volatile = ""
            var failure: (any Error)?
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finalized += text
                        volatile = ""
                    } else {
                        volatile = text
                    }
                    update((finalized + volatile).trimmingCharacters(in: .whitespaces), false, nil)
                }
            } catch {
                failure = error
            }
            let text = (finalized + volatile).trimmingCharacters(in: .whitespaces)
            update(text, true, failure)
            return text
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    func finish() async -> String {
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        return await results?.value ?? ""
    }

    func cancel() {
        input.finish()
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}

/// Converts microphone buffers to an engine's format as they arrive, on the audio thread. One
/// converter per take keeps the resampler's state between buffers.
final class DictationAudioConverter: @unchecked Sendable {
    let format: AVAudioFormat
    private var converter: AVAudioConverter?

    init(to format: AVAudioFormat) { self.format = format }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate).rounded(.up)) + 1
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        let source = DictationSourceBuffer(buffer)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard let buffer = source.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}

/// Hands the converter one buffer, once.
private final class DictationSourceBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

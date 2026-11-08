import AVFoundation
import HappierKit
import os
import Speech
import SwiftUI

/// Live speech-to-text into the composer (the Claude/ChatGPT mic button).
@MainActor
@Observable
final class Dictation {
    private static let log = Logger(subsystem: "dev.happier.apple", category: "dictation")
    private(set) var isRecording = false
    private(set) var error: String?
    /// The mic's loudness lately (0…1, newest last), for push to talk's moving bars.
    private(set) var levels: [Float] = []
    /// What's been heard in this take so far (push to talk shows it live).
    private(set) var heard = ""

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    /// Bumped on every stop. The recognizer still delivers a final transcript after `finish()`;
    /// a result from an earlier take must not write into a composer the user has already sent or edited.
    @ObservationIgnored private var take = 0
    /// Between being asked to listen and the microphone being up.
    @ObservationIgnored private var starting = false
    /// This take's hold on audio (reading aloud stays quiet while it's held). One per take, so an
    /// earlier take unwinding can't release a newer one's.
    @ObservationIgnored private var audioClaim: AudioClaim?

    private final class AudioClaim {}

    /// Holds audio for the microphone now, before anything else starts: push to talk claims it on
    /// touch-down so reading aloud can't switch the audio session while the microphone opens
    /// (that left the input with no valid format and crashed installing the tap).
    func claimAudio() {
        guard audioClaim == nil else { return }
        let claim = AudioClaim()
        audioClaim = claim
        MessageSpeaker.shared.beginRecording(claim)
    }

    private func releaseAudio() {
        guard let claim = audioClaim else { return }
        audioClaim = nil
        MessageSpeaker.shared.endRecording(claim)
    }

    init() {
        // Listing the supported languages is slow: done ahead, off the main thread, so the first
        // push to talk after launch listens at once.
        Task.detached(priority: .utility) { _ = Dictation.language }
    }
    @ObservationIgnored private var transcript = DictationTranscript()
    /// Waiting for the recognizer's last words after `finish()`.
    @ObservationIgnored private var finishing: CheckedContinuation<Void, Never>?

    /// Starts or stops dictation. `onText` receives `prefix + transcript` as it updates.
    func toggle(prefix: String, onText: @escaping @MainActor (String) -> Void) {
        if isRecording || starting {
            stop()
        } else {
            let current = take
            Task {
                guard take == current else { return }
                await start(prefix: prefix, onText: onText)
            }
        }
    }

    /// Starts listening if it isn't already (push to talk).
    func begin(prefix: String, onText: @escaping @MainActor (String) -> Void) async {
        guard !isRecording, !starting else { return }
        await start(prefix: prefix, onText: onText)
    }

    /// Stops listening but lets the recognizer deliver what it was still working on (the last
    /// words), up to a second and a half, then stops: push to talk sends right after this.
    func finish() async {
        guard isRecording, let request else {
            // Let go while the microphone was still coming up: it must not start after all
            // (it used to, without the push-to-talk panel, and the next hold did nothing).
            // Let go before it even began: give back the audio claimed on touch-down.
            if starting { stop() } else { releaseAudio() }
            return
        }
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request.endAudio()
        await withCheckedContinuation { continuation in
            finishing = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                self?.finishing?.resume()
                self?.finishing = nil
            }
        }
        stop()
    }

    func stop() {
        let usedMicrophone = isRecording || starting || engine != nil
        finishing?.resume()
        finishing = nil
        // An in-flight microphone startup releases ownership when it has actually unwound.
        defer { if !starting { releaseAudio() } }
        take += 1
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        engine = nil
        request = nil
        task = nil
        isRecording = false
        #if os(iOS)
        if usedMicrophone {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
    }

    private func start(prefix: String, onText: @escaping @MainActor (String) -> Void) async {
        error = nil
        let current = take
        starting = true
        claimAudio()
        defer {
            starting = false
            if !isRecording { releaseAudio() }
        }
        guard await Self.authorize() else {
            error = String(localized: "Allow microphone and speech recognition in Settings to dictate.")
            return
        }
        // The user's own language: the app's text is English only, so `Locale.current` is English
        // even on a Spanish phone.
        let language = await Self.dictationLanguage()
        guard take == current else { return }
        guard let recognizer = language.flatMap({ SFSpeechRecognizer(locale: Locale(identifier: $0)) }) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            error = String(localized: "Speech recognition isn't available right now.")
            return
        }
        do {
            levels = []
            heard = ""
            let (engine, request) = try await Self.openMicrophone(onDevice: recognizer.supportsOnDeviceRecognition) { [weak self] level in
                Task { @MainActor in
                    guard let self, self.isRecording else { return }
                    self.levels.append(level)
                    if self.levels.count > 40 { self.levels.removeFirst(self.levels.count - 40) }
                }
            }
            self.engine = engine
            self.request = request
            // Let go (or tapped again) while it was coming up.
            guard take == current else {
                stop()
                return
            }
            let separator = prefix.isEmpty || prefix.hasSuffix(" ") ? "" : " "
            // After a pause the recognizer reports only the new words; this keeps the earlier ones.
            transcript = DictationTranscript()
            task = Self.recognize(with: recognizer, request: request) { [weak self] text, endsUtterance, done in
                Task { @MainActor in
                    guard let self, self.take == current else { return }
                    if let text {
                        self.transcript.update(text, endsUtterance: endsUtterance)
                        self.heard = self.transcript.text
                        onText(prefix + separator + self.transcript.text)
                    }
                    if done {
                        // `finish()` is waiting for exactly this: the final words are in.
                        if let finishing = self.finishing {
                            self.finishing = nil
                            finishing.resume()
                        } else {
                            self.stop()
                        }
                    }
                }
            }
            isRecording = true
            // One ready cue for tap and hold alike, after permission, audio startup and the
            // recognizer are ready. Do not pause capture for it: the first words must be kept.
            AppHaptics.listening(true)
        } catch {
            Self.log.error("dictation failed: \(String(describing: error), privacy: .public)")
            self.error = error.localizedDescription
            stop()
        }
    }

    // Speech and audio call these closures on their own background queues. They are built in
    // nonisolated helpers so Swift 6 does not attach (and trap on) a main-actor assumption.

    /// The dictation language, worked out once (listing the supported locales is slow, and push
    /// to talk should listen the moment it's held).
    nonisolated private static let language: String? = SpeechLanguage.dictationLocale(
        preferred: Locale.preferredLanguages, region: Locale.current.region?.identifier,
        supported: SFSpeechRecognizer.supportedLocales().map(\.identifier))

    /// Off the main thread: the first time it lists every supported language.
    private nonisolated static func dictationLanguage() async -> String? { language }

    /// The audio session and the microphone. They block for a noticeable moment (longer while
    /// something was playing), so they come up off the main thread: push to talk shows at once.
    private nonisolated static func openMicrophone(onDevice: Bool, level: @escaping @Sendable (Float) -> Void) async throws
        -> sending (AVAudioEngine, SFSpeechAudioBufferRecognitionRequest) {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // Play-and-record rather than record-only: switching to record-only left the speech
        // synthesizer mute afterwards (reading aloud stopped working after the mic).
        try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        // iOS otherwise mutes the ready tone while the microphone is active.
        try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if onDevice { request.requiresOnDeviceRecognition = true }
        var engine = AVAudioEngine()
        // An input with no valid format (the audio route was still changing) would raise an
        // Objective-C exception in `installTap`, which Swift can't catch: check it, give the route
        // a moment once, then report a normal dictation error.
        if !Self.hasUsableInput(engine.inputNode) {
            try await Task.sleep(for: .milliseconds(250))
            engine = AVAudioEngine()
            guard Self.hasUsableInput(engine.inputNode) else { throw DictationError.microphoneUnavailable }
        }
        installTap(on: engine.inputNode, feeding: request, level: level)
        engine.prepare()
        try engine.start()
        return (engine, request)
    }

    private nonisolated static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    private nonisolated static func hasUsableInput(_ input: AVAudioInputNode) -> Bool {
        let format = input.outputFormat(forBus: 0)
        return format.sampleRate > 0 && format.channelCount > 0
    }

    private nonisolated static func installTap(on input: AVAudioInputNode, feeding request: SFSpeechAudioBufferRecognitionRequest,
                                               level: @escaping @Sendable (Float) -> Void) {
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
            // Loudness of this slice (RMS, as 0…1 over a −50…0 dB range) for the moving bars.
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
            let rms = (sum / Float(buffer.frameLength)).squareRoot()
            let db = 20 * log10(max(rms, 0.000_01))
            level(min(max((db + 50) / 50, 0), 1))
        }
    }

    private nonisolated static func recognize(with recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
                                              update: @escaping @Sendable (String?, Bool, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            // Metadata arrives with the last result of an utterance, when the speaker pauses.
            update(result?.bestTranscription.formattedString, result?.speechRecognitionMetadata != nil,
                   error != nil || (result?.isFinal ?? false))
        }
    }
}

/// A dictation that couldn't start, shown like any other dictation error.
enum DictationError: LocalizedError {
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable: String(localized: "The microphone isn't available right now. Try again.")
        }
    }
}

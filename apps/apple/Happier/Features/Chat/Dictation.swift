import AVFoundation
import HappierKit
import os
import Speech
import SwiftUI

/// Live speech-to-text into the composer (the Claude/ChatGPT mic button). The one owner of
/// dictation: the microphone, the take and the composer's text. The engine that turns the audio
/// into text (Whisper on the device, or Apple's) is chosen per take by `DictationRecognizers`.
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

    /// This take's hold on the app's microphone (shared with Oído, which keeps listening).
    @ObservationIgnored private var microphone: Microphone.Tap?
    @ObservationIgnored private var recognizer: (any DictationRecognizer)?
    /// Writes the take's text into the composer.
    @ObservationIgnored private var deliver: (@MainActor (String) -> Void)?
    /// Bumped on every stop. The recognizer still delivers a final transcript after `finish()`;
    /// a result from an earlier take must not write into a composer the user has already sent or edited.
    @ObservationIgnored private var take = 0
    /// Between being asked to listen and the microphone being up.
    @ObservationIgnored private var starting = false
    /// This take's report for Settings › Dictation, saved when it ends (only takes that listened).
    @ObservationIgnored private var takeLog: DictationTakeLog?
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
        Task.detached(priority: .utility) { _ = Dictation.supportedLocales }
        // Whisper's model loads now (a second or so), not when the first take begins.
        Task { await DictationRecognizers.warmUp(language: await Self.takeLanguage().apple) }
    }
    /// Waiting for the engine's last words after `finish()`.
    @ObservationIgnored private var finishing = false

    /// Starts or stops dictation. `onText` receives `prefix + transcript` as it updates. Stopping
    /// lets the engine deliver what it was still working on: Whisper transcribes the last second or
    /// so only then, and a short take only then at all.
    func toggle(prefix: String, onText: @escaping @MainActor (String) -> Void) {
        if isRecording {
            Task { await finish() }
        } else if starting {
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

    /// Stops listening but lets the engine deliver what it was still working on (the last words),
    /// then stops: push to talk sends right after this.
    func finish() async {
        guard isRecording, let recognizer, !finishing else {
            // Let go while the microphone was still coming up: it must not start after all
            // (it used to, without the push-to-talk panel, and the next hold did nothing).
            // Let go before it even began: give back the audio claimed on touch-down.
            if starting { stop() } else if !finishing { releaseAudio() }
            return
        }
        let current = take
        // No more audio for this take; Oído, if it's on, goes on listening.
        releaseMicrophone()
        finishing = true
        let text = await recognizer.finish()
        finishing = false
        // Written here, before stopping: an update still on its way would arrive after the take ended.
        if take == current {
            heard = text
            deliver?(text)
            takeLog?.shown(text)
        }
        stop()
    }

    func stop() {
        // An in-flight microphone startup releases ownership when it has actually unwound.
        defer { if !starting { releaseAudio() } }
        take += 1
        if let takeLog {
            DictationDiagnostics.shared.save(takeLog.current)
            self.takeLog = nil
        }
        releaseMicrophone()
        recognizer?.cancel()
        recognizer = nil
        deliver = nil
        isRecording = false
    }

    /// Gives the microphone back; the audio session switches off only when nothing else (Oído)
    /// still uses it.
    private func releaseMicrophone() {
        guard let microphone else { return }
        self.microphone = nil
        Microphone.shared.detach(microphone)
    }

    /// A call, Siri or another app took the microphone mid-take: keep what was heard so far.
    private func microphoneLost(take lost: Int) {
        guard take == lost, isRecording, !finishing else { return }
        Self.log.notice("dictation: the microphone was taken; finishing the take")
        Task { await finish() }
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
        // The user's own language: the app's text is English only, so `Locale.current` is English
        // even on a Spanish phone.
        let language = await Self.takeLanguage()
        // Whisper once its model is in memory, else Apple's engine while Whisper loads.
        let choice = await DictationRecognizers.take(language: language.apple)
        let engine = choice.engine
        guard take == current else { return }
        // Whisper needs only the microphone; Apple's engines also need speech recognition.
        let speechRecognition = if case .whisper = engine { false } else { true }
        guard await Self.authorize(speechRecognition: speechRecognition) else {
            error = String(localized: "Allow microphone and speech recognition in Settings to dictate.")
            return
        }
        guard take == current else { return }
        do {
            levels = []
            heard = ""
            let separator = prefix.isEmpty || prefix.hasSuffix(" ") ? "" : " "
            // Written in the user's style (Settings › Dictation), fixed for the whole take.
            let style = DictationStyle(defaults: .standard)
            let deliver: @MainActor (String) -> Void = { text in onText(prefix + separator + style.apply(text)) }
            let takeLog = DictationTakeLog(engine: engine, fallback: choice.fallback)
            let recognizer = try await DictationRecognizers.start(engine, language: language, takeLog: takeLog) { [weak self] text, ended, failure in
                Task { @MainActor in
                    guard let self, self.take == current, !self.finishing || failure != nil else { return }
                    if let failure {
                        Self.log.error("dictation failed: \(String(describing: failure), privacy: .public)")
                        self.error = failure.localizedDescription
                    }
                    if text != self.heard {
                        self.heard = text
                        deliver(text)
                        takeLog.shown(text)
                    }
                    if ended, !self.finishing { self.stop() }
                }
            }
            guard take == current else {
                recognizer.cancel()
                return
            }
            self.recognizer = recognizer
            self.deliver = deliver
            let microphone = try await Self.openMicrophone(feeding: recognizer, level: { [weak self] level in
                Task { @MainActor in
                    guard let self, self.isRecording else { return }
                    self.levels.append(level)
                    if self.levels.count > 40 { self.levels.removeFirst(self.levels.count - 40) }
                }
            }, lost: { [weak self] in
                Task { @MainActor in self?.microphoneLost(take: current) }
            })
            self.microphone = microphone
            // Let go (or tapped again) while it was coming up.
            guard take == current else {
                stop()
                return
            }
            isRecording = true
            takeLog.listening()
            self.takeLog = takeLog
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

    /// Settings › Dictation's language, a language code (`es`); none is Automatic: Whisper
    /// recognizes the language spoken. Both engines, Whisper and Apple's, dictate in a chosen one.
    static let languageKey = "happier.dictation.language"
    /// The language Whisper last recognized on Automatic (`es`): what Apple's engines, which can't
    /// recognize it, dictate in.
    nonisolated static let heardLanguageKey = "happier.dictation.heardLanguage"

    /// The recognizers' languages, listed once (listing them is slow, and push to talk should
    /// listen the moment it's held).
    nonisolated private static let supportedLocales: [String] = SFSpeechRecognizer.supportedLocales().map(\.identifier)

    /// A take's language: the one chosen in Settings, else Automatic.
    /// Off the main thread: the first time it lists every supported language.
    nonisolated static func takeLanguage() async -> DictationLanguage {
        await takeLanguage(chosen: UserDefaults.standard.string(forKey: languageKey))
    }

    /// What `chosen` (nil: Automatic) resolves to on this device.
    nonisolated static func takeLanguage(chosen: String?) async -> DictationLanguage {
        SpeechLanguage.dictation(chosen: chosen, heard: UserDefaults.standard.string(forKey: heardLanguageKey),
                                 preferred: Locale.preferredLanguages, region: Locale.current.region?.identifier,
                                 supported: supportedLocales)
    }

    /// Whisper recognized `language` (a code, `es`) in a take on Automatic.
    nonisolated static func heard(_ language: String) {
        guard UserDefaults.standard.string(forKey: heardLanguageKey) != language else { return }
        UserDefaults.standard.set(language, forKey: heardLanguageKey)
    }

    /// The languages Settings › Dictation offers.
    nonisolated static func languageChoices() async -> [String] {
        SpeechLanguage.dictationLanguages(supported: supportedLocales)
    }

    /// The microphone (the app's one, shared with Oído). It comes up off the main thread: it blocks
    /// for a noticeable moment (longer while something was playing), and push to talk shows at once.
    private nonisolated static func openMicrophone(feeding recognizer: any DictationRecognizer, level: @escaping @Sendable (Float) -> Void,
                                                   lost: @escaping @Sendable () -> Void) async throws -> Microphone.Tap {
        try await Microphone.shared.attach(.dictating, onBuffer: { buffer in
            recognizer.append(buffer)
            // Loudness of this slice (RMS, as 0…1 over a −50…0 dB range) for the moving bars.
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
            let rms = (sum / Float(buffer.frameLength)).squareRoot()
            let db = 20 * log10(max(rms, 0.000_01))
            level(min(max((db + 50) / 50, 0), 1))
        }, onPhase: { phase in
            if phase == .interrupted || phase == .waiting { lost() }
        })
    }

    private nonisolated static func authorize(speechRecognition: Bool) async -> Bool {
        if speechRecognition {
            let speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
            guard speech else { return false }
        }
        return await AVAudioApplication.requestRecordPermission()
    }
}

/// A dictation that couldn't start, shown like any other dictation error.
enum DictationError: LocalizedError {
    case recognizerUnavailable
    case modelMissing

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable: String(localized: "Speech recognition isn't available right now.")
        case .modelMissing: String(localized: "The Whisper model is missing. Download it again in Settings › Dictation.")
        }
    }
}

import AVFoundation
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

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?

    /// Starts or stops dictation. `onText` receives `prefix + transcript` as it updates.
    func toggle(prefix: String, onText: @escaping @MainActor (String) -> Void) {
        if isRecording { stop() } else { Task { await start(prefix: prefix, onText: onText) } }
    }

    func stop() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        engine = nil
        request = nil
        task = nil
        isRecording = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func start(prefix: String, onText: @escaping @MainActor (String) -> Void) async {
        error = nil
        guard await Self.authorize() else {
            error = String(localized: "Allow microphone and speech recognition in Settings to dictate.")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            error = String(localized: "Speech recognition isn't available right now.")
            return
        }
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            let engine = AVAudioEngine()
            Self.installTap(on: engine.inputNode, feeding: request)
            engine.prepare()
            try engine.start()
            let separator = prefix.isEmpty || prefix.hasSuffix(" ") ? "" : " "
            task = Self.recognize(with: recognizer, request: request) { [weak self] text, done in
                Task { @MainActor in
                    if let text { onText(prefix + separator + text) }
                    if done { self?.stop() }
                }
            }
            self.engine = engine
            self.request = request
            isRecording = true
        } catch {
            Self.log.error("dictation failed: \(String(describing: error), privacy: .public)")
            self.error = error.localizedDescription
            stop()
        }
    }

    // Speech and audio call these closures on their own background queues. They are built in
    // nonisolated helpers so Swift 6 does not attach (and trap on) a main-actor assumption.

    private nonisolated static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    private nonisolated static func installTap(on input: AVAudioInputNode, feeding request: SFSpeechAudioBufferRecognitionRequest) {
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
    }

    private nonisolated static func recognize(with recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
                                              update: @escaping @Sendable (String?, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            update(result?.bestTranscription.formattedString, error != nil || (result?.isFinal ?? false))
        }
    }
}

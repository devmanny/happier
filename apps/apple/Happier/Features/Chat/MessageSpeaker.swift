import AVFoundation
import HappierKit
import NaturalLanguage
import SwiftUI

/// Reads a message aloud with the system voices (offline, the voices installed in Settings). One
/// message at a time: speaking another one, or the same one again, stops the current reading.
@MainActor
@Observable
final class MessageSpeaker: NSObject {
    static let shared = MessageSpeaker()

    /// The Markdown of the message being read.
    private(set) var speakingText: String?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var currentUtterance: ObjectIdentifier?

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    func isSpeaking(_ markdown: String) -> Bool { speakingText == markdown }

    func toggle(_ markdown: String) {
        if speakingText == markdown {
            synthesizer.stopSpeaking(at: .immediate)
            finish()
        } else {
            speak(markdown)
        }
    }

    private func speak(_ markdown: String) {
        let spoken = SpokenText.from(markdown: markdown)
        guard !spoken.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        #if os(iOS)
        // Plays with the silent switch on, lowering other audio while it reads.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = Self.voice(for: spoken)
        currentUtterance = ObjectIdentifier(utterance)
        speakingText = markdown
        synthesizer.speak(utterance)
    }

    /// The voice for the text's language, in the user's own region when it is the same language
    /// (Mexican Spanish for a Spanish message on an es-MX phone).
    private static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage?.rawValue else { return nil }
        if Locale.current.language.languageCode?.identifier == language,
           let regional = AVSpeechSynthesisVoice(language: Locale.current.identifier.replacingOccurrences(of: "_", with: "-")) {
            return regional
        }
        return AVSpeechSynthesisVoice(language: language)
    }

    fileprivate func finished(_ utterance: ObjectIdentifier) {
        // A reading replaced by another one also reports cancellation; only clear for the current one.
        guard utterance == currentUtterance else { return }
        finish()
    }

    private func finish() {
        currentUtterance = nil
        speakingText = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

extension MessageSpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(id) }
    }
}

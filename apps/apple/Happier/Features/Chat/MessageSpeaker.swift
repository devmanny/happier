import AVFoundation
import HappierKit
import NaturalLanguage
import SwiftUI

/// Reads a message aloud with the system voices (offline, the voices installed in Settings), one
/// sentence at a time so it can pause, skip back and forward, and change speed mid-sentence. One
/// message at a time: speaking another one, or the same one again, stops the current reading.
@MainActor
@Observable
final class MessageSpeaker: NSObject {
    static let shared = MessageSpeaker()

    /// The Markdown of the message being read.
    private(set) var speakingText: String?
    private(set) var isPaused = false
    private(set) var sentenceIndex = 0
    private(set) var sentenceCount = 0
    /// Multiple of the voice's normal pace; kept between readings.
    private(set) var rate: Double

    private static let rateKey = "happier.speech.rate"

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var sentences: [String] = []
    @ObservationIgnored private var voice: AVSpeechSynthesisVoice?
    @ObservationIgnored private var currentUtterance: ObjectIdentifier?
    /// Where in the current sentence (UTF-16) the utterance started, and the word it has reached.
    @ObservationIgnored private var utteranceStart = 0
    @ObservationIgnored private var wordInUtterance = 0
    /// A speed change while paused takes effect on resume.
    @ObservationIgnored private var restartOnResume = false

    override private init() {
        let stored = UserDefaults.standard.double(forKey: Self.rateKey)
        // A little quicker than the voice's normal pace until you pick another speed.
        rate = SpeechRate.steps.contains(stored) ? stored : 1.2
        super.init()
        synthesizer.delegate = self
    }

    func isSpeaking(_ markdown: String) -> Bool { speakingText == markdown }

    func toggle(_ markdown: String) {
        if speakingText == markdown {
            stop()
        } else {
            start(markdown)
        }
    }

    func togglePause() {
        guard speakingText != nil else { return }
        if isPaused {
            isPaused = false
            if restartOnResume {
                restartOnResume = false
                speakSentence(from: position)
            } else {
                synthesizer.continueSpeaking()
            }
        } else {
            isPaused = true
            synthesizer.pauseSpeaking(at: .word)
        }
    }

    func forward() {
        guard speakingText != nil else { return }
        guard sentenceIndex + 1 < sentences.count else {
            stop()
            return
        }
        sentenceIndex += 1
        resumePlaying(from: 0)
    }

    /// Like a music player: back to the start of this sentence, or to the previous one when
    /// it has barely begun.
    func back() {
        guard speakingText != nil else { return }
        if position < 12, sentenceIndex > 0 { sentenceIndex -= 1 }
        resumePlaying(from: 0)
    }

    func faster() { setRate(SpeechRate.faster(rate)) }
    func slower() { setRate(SpeechRate.slower(rate)) }

    func stop() {
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        finish()
    }

    // MARK: Reading

    /// UTF-16 offset reached in the current sentence.
    private var position: Int { utteranceStart + wordInUtterance }

    private func start(_ markdown: String) {
        let parts = SpokenText.sentences(markdown: markdown)
        guard !parts.isEmpty else { return }
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        #if os(iOS)
        // Plays with the silent switch on, lowering other audio while it reads.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        sentences = parts
        voice = Self.voice(for: parts.joined(separator: " "))
        sentenceIndex = 0
        sentenceCount = parts.count
        isPaused = false
        speakingText = markdown
        speakSentence(from: 0)
    }

    private func setRate(_ newRate: Double) {
        guard newRate != rate else { return }
        rate = newRate
        UserDefaults.standard.set(newRate, forKey: Self.rateKey)
        guard speakingText != nil else { return }
        // Picks up at the word it was saying, at the new speed.
        if isPaused {
            restartOnResume = true
        } else {
            speakSentence(from: position)
        }
    }

    private func resumePlaying(from offset: Int) {
        isPaused = false
        restartOnResume = false
        speakSentence(from: offset)
    }

    private func speakSentence(from offset: Int) {
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        guard sentenceIndex < sentences.count else {
            finish()
            return
        }
        let sentence = sentences[sentenceIndex] as NSString
        let start = min(max(offset, 0), sentence.length)
        let utterance = AVSpeechUtterance(string: sentence.substring(from: start))
        utterance.voice = voice
        utterance.rate = min(max(AVSpeechUtteranceDefaultSpeechRate * Float(rate), AVSpeechUtteranceMinimumSpeechRate),
                             AVSpeechUtteranceMaximumSpeechRate)
        utteranceStart = start
        wordInUtterance = 0
        currentUtterance = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
    }

    /// The voice for the text's language: the one picked in Settings, else the most natural one
    /// installed, in the user's region when two are as good (Mexican Spanish on an es-MX phone).
    private static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage?.rawValue else { return nil }
        return voice(language: language)
    }

    static func voice(language: String) -> AVSpeechSynthesisVoice? {
        let chosen = UserDefaults.standard.string(forKey: voiceKey(language))
        guard let pick = SpeechLanguage.voice(for: language, region: Locale.current.region?.identifier,
                                              among: installedVoices(), chosen: chosen) else {
            return AVSpeechSynthesisVoice(language: language)
        }
        return AVSpeechSynthesisVoice(identifier: pick.id)
    }

    /// The voices installed on this device, without the novelty ones (Bubbles, Bad News…).
    static func installedVoices() -> [SpeechLanguage.Voice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
            .map { voice in
                let quality = switch voice.quality {
                case .premium: 2
                case .enhanced: 1
                default: 0
                }
                return SpeechLanguage.Voice(id: voice.identifier, name: voice.name, language: voice.language, quality: quality)
            }
    }

    /// The voice picked in Settings for a language (nil: the most natural one installed).
    static func voiceKey(_ language: String) -> String { "happier.speech.voice.\(language)" }

    /// Plays a short sample in a voice, for picking one.
    func preview(_ voice: AVSpeechSynthesisVoice?, language: String) {
        if speakingText != nil { stop() }
        synthesizer.stopSpeaking(at: .immediate)
        let sample = language == "es" ? "Hola, así sueno cuando leo tus mensajes." : "Hi, this is how I sound reading your messages."
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let utterance = AVSpeechUtterance(string: sample)
        utterance.voice = voice
        utterance.rate = min(max(AVSpeechUtteranceDefaultSpeechRate * Float(rate), AVSpeechUtteranceMinimumSpeechRate),
                             AVSpeechUtteranceMaximumSpeechRate)
        currentUtterance = nil
        synthesizer.speak(utterance)
    }

    fileprivate func finished(_ utterance: ObjectIdentifier) {
        // A sentence cut short by a skip or a speed change also ends; only the current one counts.
        guard utterance == currentUtterance else { return }
        sentenceIndex += 1
        if sentenceIndex < sentences.count {
            speakSentence(from: 0)
        } else {
            finish()
        }
    }

    fileprivate func reached(_ location: Int, in utterance: ObjectIdentifier) {
        guard utterance == currentUtterance else { return }
        wordInUtterance = location
    }

    private func finish() {
        currentUtterance = nil
        speakingText = nil
        isPaused = false
        restartOnResume = false
        sentences = []
        sentenceIndex = 0
        sentenceCount = 0
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

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        let location = characterRange.location
        Task { @MainActor in self.reached(location, in: id) }
    }
}

/// The reading's controls, floating above the composer while a message is read aloud: back,
/// slower, the speed, faster, play/pause, forward, and close; a thin line shows the progress.
struct SpeechControls: View {
    @State private var speaker = MessageSpeaker.shared

    var body: some View {
        HStack(spacing: 2) {
            control("Back", systemImage: "backward.fill") { speaker.back() }
            control("Slower", systemImage: "tortoise.fill") { speaker.slower() }
                .disabled(speaker.rate <= SpeechRate.steps.first!)
            Text(SpeechRate.label(speaker.rate))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
                .frame(minWidth: 44)
                .accessibilityLabel(Text("Speed \(SpeechRate.label(speaker.rate))"))
            control("Faster", systemImage: "hare.fill") { speaker.faster() }
                .disabled(speaker.rate >= SpeechRate.steps.last!)
            control(speaker.isPaused ? "Play" : "Pause", systemImage: speaker.isPaused ? "play.fill" : "pause.fill") {
                speaker.togglePause()
            }
            .font(.title3)
            control("Forward", systemImage: "forward.fill") { speaker.forward() }
            control("Stop Reading", systemImage: "xmark") { speaker.stop() }
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            GeometryReader { proxy in
                let fraction = speaker.sentenceCount > 0 ? Double(speaker.sentenceIndex + 1) / Double(speaker.sentenceCount) : 0
                Capsule()
                    .fill(Color.userBubble)
                    .frame(width: proxy.size.width * fraction, height: 2)
                    .animation(.smooth, value: fraction)
            }
            .frame(height: 2)
            .padding(.horizontal, 18)
            .accessibilityHidden(true)
        }
        .glassEffect(.regular, in: Capsule())
        .animation(.smooth(duration: 0.2), value: speaker.rate)
        .sensoryFeedback(.selection, trigger: speaker.rate)
    }

    private func control(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 40, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentTransition(.symbolEffect(.replace))
        .accessibilityLabel(Text(title))
    }
}

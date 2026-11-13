import AVFoundation
import HappierKit
#if os(iOS)
import ActivityKit
import MediaPlayer
#endif
import SwiftUI

/// Reads a message aloud with the system voices (offline, the voices installed in Settings), one
/// sentence at a time so it can pause, skip back and forward, and change speed mid-sentence.
/// Messages are read in a queue: picking one by hand reads it alone; auto read (per
/// conversation) adds each new agent message after the others, so none cuts another off, and the
/// player can jump a whole message back or ahead.
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
    /// The messages read and waiting.
    private(set) var queue = ReadAloudQueue()
    /// The conversation whose new agent messages are read as they arrive.
    private(set) var autoReadSessionId: String?
    /// The conversation a message was picked in by hand, when known.
    private(set) var pickedSessionId: String?
    @ObservationIgnored private var autoReadCursor: AutoReadCursor?
    /// Follows the auto-read conversation in the store, not on screen, so it keeps going with
    /// the app in the background.
    @ObservationIgnored private var followTask: Task<Void, Never>?
    /// Silence playing while auto read waits in the background, so iOS keeps the app running.
    @ObservationIgnored private var keepAlive: AVAudioEngine?
    /// What the Live Activity calls the reading: the auto-read conversation's title.
    @ObservationIgnored private var readingTitle = String(localized: "Reading aloud")
    @ObservationIgnored private weak var autoReadStore: HappierStore?
    /// Dictation owns audio through permission/startup, capture and its final transcription.
    /// Multiple composer windows must not release another recorder's suspension.
    @ObservationIgnored private var recordingOwners: Set<ObjectIdentifier> = []
    @ObservationIgnored private var isInBackground = false
    /// Auto read stops by itself after 10 minutes in the background with nothing to read.
    @ObservationIgnored private var idle = AutoReadIdle()
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    /// Set while auto read stops for being idle, so the Live Activity ends saying so.
    #if os(iOS)
    @ObservationIgnored private var activity: Activity<ReadAloudAttributes>?
    @ObservationIgnored private var requestingActivity = false
    #endif

    private static let rateKey = "happier.speech.rate"

    @ObservationIgnored private var synthesizer = AVSpeechSynthesizer()
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
        installRemoteCommands()
    }

    func isSpeaking(_ markdown: String) -> Bool { speakingText == markdown }

    /// Whether the window of `sessionId` shows the player (`ReadAloudQueue.showsPlayer`).
    func showsPlayer(in sessionId: String) -> Bool {
        speakingText != nil && queue.showsPlayer(in: sessionId, picked: pickedSessionId, autoRead: autoReadSessionId)
    }

    func toggle(_ markdown: String, sessionId: String? = nil) {
        guard recordingOwners.isEmpty else { return }
        if speakingText == markdown {
            stop()
        } else {
            pickedSessionId = sessionId
            queue.play(.init(id: ReadAloudQueue.pickedId(markdown), text: markdown))
            if autoReadSessionId == nil { readingTitle = String(localized: "Reading aloud") }
            start(markdown)
        }
    }

    // MARK: Auto read

    func beginRecording(_ owner: AnyObject) {
        guard recordingOwners.insert(ObjectIdentifier(owner)).inserted else { return }
        setKeepAlive(false)
        stop()
        skipRecordingBacklog()
    }

    func endRecording(_ owner: AnyObject) {
        guard recordingOwners.contains(ObjectIdentifier(owner)) else { return }
        // Capture the final store state even if its observation callback hasn't run yet.
        skipRecordingBacklog()
        recordingOwners.remove(ObjectIdentifier(owner))
        guard recordingOwners.isEmpty else { return }
        // The microphone can leave the old synthesizer silent; recreate it before the next reply.
        synthesizer.delegate = nil
        synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        if autoReadSessionId != nil { mixWithOthers() }
        setKeepAlive(isInBackground && autoReadSessionId != nil)
    }

    private func skipRecordingBacklog() {
        guard let sessionId = autoReadSessionId, let store = autoReadStore else { return }
        _ = autoReadCursor?.take(store.transcripts[sessionId]?.items ?? [], turnActive: false, recording: true)
    }

    /// Turns reading new agent messages of `sessionId` on or off; what's already there isn't read.
    func toggleAutoRead(_ sessionId: String, store: HappierStore) {
        followTask?.cancel()
        followTask = nil
        if autoReadSessionId == sessionId {
            autoReadSessionId = nil
            autoReadCursor = nil
            autoReadStore = nil
            idleTask?.cancel()
            idleTask = nil
            idle = AutoReadIdle()
            store.keepsConnectionInBackground = false
            setKeepAlive(false)
            if speakingText == nil { deactivateAudio() }
            refreshActivity()
            return
        }
        autoReadSessionId = sessionId
        autoReadStore = store
        readingTitle = store.sessions[sessionId]?.title ?? String(localized: "Reading aloud")
        autoReadCursor = AutoReadCursor(existing: store.transcripts[sessionId]?.items ?? [])
        // New messages must keep arriving with the app minimized.
        store.keepsConnectionInBackground = true
        idle = AutoReadIdle()
        refreshActivity()
        followTask = Task { [weak self, weak store] in
            while !Task.isCancelled, let store {
                self?.feed(sessionId, items: store.transcripts[sessionId]?.items ?? [],
                           turnActive: store.sessions[sessionId]?.thinking ?? false)
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = store.transcripts[sessionId]?.items
                        _ = store.sessions[sessionId]?.thinking
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// The app went to the background (or came back): while auto read waits for the next
    /// message, silence keeps iOS from suspending it.
    func appMovedToBackground(_ background: Bool) {
        isInBackground = background
        let wasAsleep = idle.isAsleep
        noteIdle()
        setKeepAlive(background && autoReadSessionId != nil && !idle.isAsleep)
        // Back in front (from the Live Activity too): auto read wakes, keeps the connection again
        // and reads what came in while it slept.
        if wasAsleep, !idle.isAsleep, let sessionId = autoReadSessionId, let store = autoReadStore {
            store.keepsConnectionInBackground = true
            refreshActivity()
            feed(sessionId, items: store.transcripts[sessionId]?.items ?? [], turnActive: store.sessions[sessionId]?.thinking ?? false)
        }
    }

    /// Re-arms the idle stop after anything that changes whether there is something to read.
    private func noteIdle() {
        guard autoReadSessionId != nil else { return }
        // The agent thinking or running tools isn't something to read: only messages count.
        let state = AutoReadIdle.State(reading: speakingText != nil, waiting: queue.waiting, inBackground: isInBackground)
        let now = Date().timeIntervalSince1970
        idle.note(state, at: now)
        idleTask?.cancel()
        idleTask = nil
        guard let deadline = idle.deadline else { return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline - now)))
            guard !Task.isCancelled else { return }
            self?.pauseIfIdle()
        }
    }

    /// Five minutes in the background with nothing new to read: auto read goes to sleep. The
    /// silent keep-alive stops, the connection goes back to the ordinary background (suspended),
    /// and the Live Activity says it's paused; it wakes when the app comes back to the front.
    private func pauseIfIdle() {
        guard autoReadSessionId != nil, let store = autoReadStore,
              idle.sleepIfDue(at: Date().timeIntervalSince1970) else { return }
        setKeepAlive(false)
        store.keepsConnectionInBackground = false
        refreshActivity()
    }

    /// The conversation changed: its newly completed agent messages join the queue.
    func feed(_ sessionId: String, items: [ChatItem], turnActive: Bool) {
        // Asleep, what arrives waits: it's read on waking.
        guard autoReadSessionId == sessionId, !idle.isAsleep, var cursor = autoReadCursor else { return }
        let changes = cursor.take(items, turnActive: turnActive, recording: !recordingOwners.isEmpty)
        autoReadCursor = cursor
        defer {
            if !changes.isEmpty { refreshActivity() }
            noteIdle()
        }
        for change in changes {
            switch change {
            case .new(let block):
                if let now = queue.enqueue(block) { start(now.text) }
            case .grew(let id, let added, let text):
                // Streamed messages keep growing: the new part is read too, after what came before.
                switch queue.grow(id: id, text: text, added: added) {
                case .appendToCurrent(let more):
                    sentences += SpokenText.sentences(markdown: more)
                    sentenceCount = sentences.count
                case .started(let block):
                    start(block.text)
                case .updated, .queued:
                    break
                }
            }
        }
    }

    /// The next whole message.
    func nextBlock() {
        if let next = queue.advance() { start(next.text) } else { endReading() }
    }

    /// The previous whole message (or this one again from its start when it's the first).
    func previousBlock() {
        if let previous = queue.previous() {
            start(previous.text)
        } else if speakingText != nil {
            sentenceIndex = 0
            resumePlaying(from: 0)
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
        refreshActivity()
    }

    func forward() {
        guard speakingText != nil else { return }
        guard sentenceIndex + 1 < sentences.count else {
            nextBlock()
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

    /// Everything off (the Live Activity's stop): this reading, what waits, and auto read.
    func stopEverything() {
        if let sessionId = autoReadSessionId, let store = autoReadStore {
            toggleAutoRead(sessionId, store: store)
        }
        stop()
    }

    /// Stops reading and drops what was waiting; auto read stays on for new messages.
    func stop() {
        queue.clear()
        endReading()
    }

    private func endReading() {
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        finish()
    }

    // MARK: Reading

    /// UTF-16 offset reached in the current sentence.
    private var position: Int { utteranceStart + wordInUtterance }

    private func start(_ markdown: String) {
        guard recordingOwners.isEmpty else { return }
        let parts = SpokenText.sentences(markdown: markdown)
        guard !parts.isEmpty else { return }
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        #if os(iOS)
        // Plays with the silent switch on and the app minimized, lowering other audio while it reads.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        publishNowPlaying(markdown)
        sentences = parts
        voice = Self.voice(for: parts.joined(separator: " "))
        sentenceIndex = 0
        sentenceCount = parts.count
        isPaused = false
        speakingText = markdown
        speakSentence(from: 0)
        refreshActivity()
        noteIdle()
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
        let language = SpeechLanguage.readingLanguage(for: text, allowed: readingLanguages)
        return voice(language: language)
    }

    /// Device-local choices, shared by the settings UI and every read-aloud entry point.
    static let languagesKey = "happier.speech.languages"
    static var readingLanguages: [String] {
        SpeechLanguage.readingLanguages(preferred: Locale.preferredLanguages,
            chosen: (UserDefaults.standard.string(forKey: languagesKey) ?? "").split(separator: ",").map(String.init))
    }

    static func voice(language: String) -> AVSpeechSynthesisVoice? {
        let chosen = UserDefaults.standard.string(forKey: voiceKey(language))
        guard let pick = SpeechLanguage.voice(for: language, region: Locale.current.region?.identifier,
                                              among: installedVoices(), chosen: chosen) else {
            return AVSpeechSynthesisVoice(language: language)
        }
        return AVSpeechSynthesisVoice(identifier: pick.id)
    }

    /// The installed voices, listed once off the main thread (`speechVoices()` waits on a system
    /// accessibility lock and held the main thread while reading started). Until the list is in,
    /// a reading uses the language's default voice.
    nonisolated private static let voiceList = VoiceList()

    private final class VoiceList: @unchecked Sendable {
        private let lock = NSLock()
        private var voices: [SpeechLanguage.Voice]?
        private var loading = false

        func cached() -> [SpeechLanguage.Voice]? {
            lock.withLock { voices }
        }

        func load() {
            let start = lock.withLock { () -> Bool in
                guard voices == nil, !loading else { return false }
                loading = true
                return true
            }
            guard start else { return }
            Task.detached(priority: .utility) { [self] in
                let list = MessageSpeaker.listInstalledVoices()
                lock.withLock { voices = list; loading = false }
            }
        }
    }

    /// Starts listing the voices in the background (at launch).
    nonisolated static func prepareVoices() { voiceList.load() }

    /// The voices installed on this device, without the novelty ones (Bubbles, Bad News…).
    static func installedVoices() -> [SpeechLanguage.Voice] {
        if let cached = voiceList.cached() { return cached }
        voiceList.load()
        return []
    }

    nonisolated static func listInstalledVoices() -> [SpeechLanguage.Voice] {
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
        guard recordingOwners.isEmpty else { return }
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
        } else if let next = queue.advance() {
            // This message is done; the next one waiting starts.
            start(next.text)
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
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #endif
        // Auto read keeps the audio session for the next message (other audio back to full volume).
        if autoReadSessionId == nil { deactivateAudio() } else { mixWithOthers() }
        refreshActivity()
        noteIdle()
    }

    // MARK: Live Activity

    /// Shows what's being read on the Dynamic Island and the Lock Screen, while reading or while
    /// auto read waits for the next message; gone once both are over.
    private func refreshActivity() {
        #if os(iOS)
        guard speakingText != nil || autoReadSessionId != nil else {
            if let activity {
                self.activity = nil
                // ActivityKit's handles are safe to use from any task.
                nonisolated(unsafe) let ending = activity
                Task { await ending.end(nil, dismissalPolicy: .immediate) }
            }
            return
        }
        if idle.isAsleep {
            let asleep = ActivityContent(state: ReadAloudAttributes.ContentState(
                title: String(localized: "Auto-read paused"),
                snippet: String(localized: "Nothing new to read for 5 minutes. Open Happier to resume."),
                isSpeaking: false, isPaused: true, waiting: 0, autoRead: true), staleDate: nil)
            if let activity {
                nonisolated(unsafe) let current = activity
                Task { await current.update(asleep) }
            }
            return
        }
        let state = ReadAloudAttributes.ContentState(
            title: readingTitle,
            snippet: String((sentences.first ?? "").prefix(120)),
            isSpeaking: speakingText != nil,
            isPaused: isPaused,
            waiting: queue.waiting,
            autoRead: autoReadSessionId != nil)
        let content = ActivityContent(state: state, staleDate: nil)
        if let activity {
            nonisolated(unsafe) let current = activity
            Task { await current.update(content) }
        } else if !requestingActivity {
            // Requesting it is slow the first time (it held the first press of the microphone for
            // up to a second): it's asked for off the main thread, and the latest state is applied
            // once it exists.
            requestingActivity = true
            Task.detached(priority: .userInitiated) {
                let created: Activity<ReadAloudAttributes>? = ActivityAuthorizationInfo().areActivitiesEnabled
                    ? try? Activity.request(attributes: ReadAloudAttributes(), content: content)
                    : nil
                nonisolated(unsafe) let handle = created
                await MainActor.run {
                    MessageSpeaker.shared.activityRequested(handle)
                }
            }
        }
        #endif
    }

    #if os(iOS)
    /// The Live Activity asked for in `refreshActivity` exists (or couldn't be made): keep it if
    /// reading is still on, and bring it to the current state.
    fileprivate func activityRequested(_ created: Activity<ReadAloudAttributes>?) {
        requestingActivity = false
        guard let created else { return }
        activity = created
        refreshActivity() // Ends it again when reading stopped meanwhile.
    }
    #endif

    private func deactivateAudio() {
        guard recordingOwners.isEmpty else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func mixWithOthers() {
        guard recordingOwners.isEmpty else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    /// Silent audio while waiting in the background: iOS keeps an app running only while it plays.
    private func setKeepAlive(_ on: Bool) {
        #if os(iOS)
        if !on || !recordingOwners.isEmpty {
            keepAlive?.stop()
            keepAlive = nil
            return
        }
        guard keepAlive == nil else { return }
        if speakingText == nil { mixWithOthers() }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return }
        silence.frameLength = silence.frameCapacity
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            player.scheduleBuffer(silence, at: nil, options: .loops)
            player.play()
            keepAlive = engine
        } catch {
            keepAlive = nil
        }
        #endif
    }

    // MARK: Lock Screen and Control Center

    private func publishNowPlaying(_ markdown: String) {
        #if os(iOS)
        let firstLine = SpokenText.sentences(markdown: markdown).first ?? ""
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: String(firstLine.prefix(80)),
            MPMediaItemPropertyArtist: "Happier",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        #endif
    }

    /// Play/pause and previous/next message from the Lock Screen, Control Center and headphones.
    private func installRemoteCommands() {
        #if os(iOS)
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.speakingText != nil else { return .noActionableNowPlayingItem }
            self.togglePause()
            return .success
        }
        center.playCommand.addTarget { [weak self] _ in
            guard let self, self.speakingText != nil, self.isPaused else { return .commandFailed }
            self.togglePause()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.speakingText != nil, !self.isPaused else { return .commandFailed }
            self.togglePause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.speakingText != nil else { return .noActionableNowPlayingItem }
            self.nextBlock()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, self.speakingText != nil else { return .noActionableNowPlayingItem }
            self.previousBlock()
            return .success
        }
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

/// The reading's controls, floating above the composer while a message is read aloud: previous
/// message, back a sentence, slower, the speed, faster, play/pause, forward a sentence, next
/// message (with how many wait), and close; a thin line shows the progress.
struct SpeechControls: View {
    @State private var speaker = MessageSpeaker.shared

    var body: some View {
        HStack(spacing: 0) {
            control("Previous Message", systemImage: "backward.end.fill") { speaker.previousBlock() }
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
            control("Next Message", systemImage: "forward.end.fill") { speaker.nextBlock() }
                .disabled(!speaker.queue.hasNext)
                .overlay(alignment: .topTrailing) {
                    // How many messages are waiting their turn.
                    if speaker.queue.waiting > 0 {
                        Text("\(speaker.queue.waiting)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .background(Color.userBubble, in: Capsule())
                            .offset(x: -2, y: 2)
                            .contentTransition(.numericText())
                    }
                }
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
                .frame(width: 33, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .contentTransition(.symbolEffect(.replace))
        .accessibilityLabel(Text(title))
    }
}

/// The toolbar's auto read switch, beside the usage ring: reads each new agent message of this
/// conversation as it arrives, queued after the one being read.
struct AutoReadButton: View {
    let sessionId: String
    /// The conversation's bubble color, shown while on.
    var color: Color = .userBubble
    @State private var speaker = MessageSpeaker.shared
    @Environment(HappierStore.self) private var store

    private var on: Bool { speaker.autoReadSessionId == sessionId }

    var body: some View {
        Button {
            AppHaptics.light()
            speaker.toggleAutoRead(sessionId, store: store)
        } label: {
            Label(on ? "Stop Reading New Messages" : "Read New Messages Aloud",
                  systemImage: on ? "speaker.wave.2.fill" : "speaker.wave.2")
        }
        .tint(on ? color : nil)
        .symbolEffect(.variableColor.iterative, isActive: on && speaker.speakingText != nil)
        .help(on ? "Stop reading new messages aloud" : "Read each new message aloud as it arrives")
    }
}

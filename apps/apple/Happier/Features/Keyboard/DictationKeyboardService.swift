#if os(iOS)
import AVFoundation
import HappierKit
import os
import SwiftUI

/// The app's side of the dictation keyboard. A keyboard can't use the microphone, so the keyboard
/// opens the app (`happier-native://keyboard-dictation`), which turns the microphone on and keeps it
/// on in the background for `standbyDuration`. Meanwhile the keyboard starts
/// and stops takes by command, without leaving the app in use, and types the text published here.
/// Takes are ordinary `Dictation` takes (Whisper, else Apple's engine), on the app's one microphone.
@MainActor
@Observable
final class DictationKeyboardService {
    /// How long the microphone stays on after the last take.
    static let standbyDuration: TimeInterval = 5 * 60
    /// How often a live app says so (`Status.heartbeat`), and checks whether its standby ran out.
    private static let heartbeatInterval: Duration = .seconds(15)
    private static let log = Logger(subsystem: "dev.happier.apple", category: "keyboard-dictation")

    /// The panel shown over the app while it was opened from the keyboard.
    var showsPanel = false
    private(set) var status = DictationKeyboard.Status()
    let dictation = Dictation()

    @ObservationIgnored private let channel = DictationKeyboard.Channel()
    @ObservationIgnored private var commands: DictationKeyboard.Observer?
    @ObservationIgnored private var standby: Microphone.Tap?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var watch: Task<Void, Never>?

    init() {
        guard let channel else {
            Self.log.error("keyboard dictation: the App Group container isn't reachable")
            return
        }
        commands = DictationKeyboard.observe(DictationKeyboard.commandNotification) { [weak self] in
            self?.commandArrived()
        }
        // A status left by an earlier run (the app killed with the microphone on) is stale: the
        // microphone is off now. The take count goes on, so the keyboard never mixes two takes.
        status.take = channel.readStatus()?.take ?? 0
        publish()
    }

    /// Happier went to the background since it was last active.
    private var cameFromBackground = false

    var microphoneOn: Bool { standby != nil }

    /// Opened from the keyboard: the microphone on, nothing more. The panel sends you back, and the
    /// keyboard's next tap starts the take where you're typing.
    func openedFromKeyboard() {
        showsPanel = true
        Task { _ = await turnOnMicrophone() }
    }

    /// Ends the take, typing its last words.
    func finishTake() async {
        guard dictation.isRecording else { return }
        status.phase = .finishing
        publish()
        await dictation.finish()
        takeEnded()
    }

    /// Back in Happier: a keyboard take still recording was left behind in the app you were typing
    /// in (no stop tapped). It ends here, typing its last words there; left running it would keep
    /// Whisper working and hold the audio, so reading a message aloud wouldn't start.
    func appBecameActive() {
        // Only back from the background: on an iPad, Happier's window can stay on screen beside the
        // app being typed in and turn active again as focus moves, while the keyboard's take goes on.
        guard cameFromBackground else { return }
        cameFromBackground = false
        guard dictation.isRecording else { return }
        Self.log.notice("keyboard dictation: back in the app with a take still recording; finishing it")
        Task { await finishTake() }
    }

    /// Happier left the screen: the panel is done, and a take still recording when it comes back
    /// was left behind.
    func appEnteredBackground() {
        showsPanel = false
        cameFromBackground = true
    }

    /// The microphone off now (the panel's button, or the keyboard's).
    func turnOff() {
        if dictation.isRecording { dictation.stop() }
        watch?.cancel()
        heartbeat?.cancel()
        heartbeat = nil
        if let standby {
            self.standby = nil
            Microphone.shared.detach(standby)
            Task { await WhisperRuntime.shared.keepLoadedInBackground(false) }
            Self.log.notice("keyboard dictation: microphone off")
        }
        status.phase = .off
        status.standbyUntil = nil
        publish()
    }

    // MARK: Takes

    private func startTake() async {
        guard standby != nil, !dictation.isRecording else { return }
        status.take += 1
        status.text = ""
        status.final = false
        status.error = nil
        status.phase = .starting
        extendStandby()
        let take = status.take
        await dictation.begin(prefix: "") { [weak self] text in
            guard let self, self.status.take == take, !self.status.final else { return }
            self.status.text = text
            self.publish()
        }
        guard status.take == take else { return }
        guard dictation.isRecording else {
            Self.log.error("keyboard dictation: the take didn't start: \(self.dictation.error ?? "-", privacy: .public)")
            status.error = dictation.error ?? MicrophoneError.unavailable.localizedDescription
            takeEnded()
            return
        }
        status.phase = .recording
        publish()
        watchTake(take)
    }

    /// The engine can end a take by itself (an error, the microphone taken): the keyboard hears of it.
    private func watchTake(_ take: Int) {
        watch?.cancel()
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.status.take == take else { return }
                if !self.dictation.isRecording {
                    if self.status.phase == .recording {
                        self.status.error = self.dictation.error
                        self.takeEnded()
                    }
                    return
                }
            }
        }
    }

    private func takeEnded() {
        status.final = true
        status.phase = standby == nil ? .off : .ready
        extendStandby()
    }

    // MARK: The microphone

    /// Turns the microphone on for the keyboard (or keeps it on longer). Only from the foreground:
    /// iOS doesn't let an app in the background start recording.
    private func turnOnMicrophone() async -> Bool {
        if standby != nil {
            extendStandby()
            return true
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            status.error = String(localized: "Allow the microphone for Happier in Settings to dictate.")
            publish()
            return false
        }
        do {
            standby = try await Microphone.shared.attach(.standby, onBuffer: { _ in }, onPhase: { [weak self] phase in
                // A call or another app took the microphone: it can't come back from the background.
                guard phase == .interrupted || phase == .waiting else { return }
                Task { @MainActor in self?.microphoneLost() }
            })
        } catch {
            Self.log.error("keyboard dictation: microphone didn't start: \(String(describing: error), privacy: .public)")
            status.error = error.localizedDescription
            publish()
            return false
        }
        await WhisperRuntime.shared.keepLoadedInBackground(true)
        Self.log.notice("keyboard dictation: microphone on")
        startHeartbeat()
        status.phase = .ready
        extendStandby()
        return true
    }

    private func microphoneLost() {
        guard standby != nil else { return }
        Self.log.notice("keyboard dictation: the microphone was taken; turning off")
        turnOff()
    }

    private func extendStandby() {
        if standby != nil { status.standbyUntil = .now.addingTimeInterval(Self.standbyDuration) }
        publish()
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard let self, !Task.isCancelled else { return }
                if let until = self.status.standbyUntil, until <= .now, !self.dictation.isRecording {
                    self.turnOff()
                    return
                }
                self.publish()
            }
        }
    }

    // MARK: The keyboard

    private func commandArrived() {
        guard let command = channel?.readCommand(), command.isFresh(), command.id != status.command else { return }
        status.command = command.id
        Self.log.notice("keyboard dictation: \(command.action.rawValue, privacy: .public)")
        switch command.action {
        case .start:
            if standby == nil {
                // Off (it ran out meanwhile): the keyboard opens the app instead.
                publish()
            } else {
                Task { await startTake() }
            }
        case .finish:
            Task { await finishTake() }
        case .cancel:
            if dictation.isRecording { dictation.stop() }
            takeEnded()
        case .endStandby:
            turnOff()
        }
    }

    private func publish() {
        status.heartbeat = .now
        channel?.publish(status)
    }
}
#endif

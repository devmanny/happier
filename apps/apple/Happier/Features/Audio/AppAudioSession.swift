import AVFoundation
import HappierKit
import os

/// The one owner of the iPhone's audio session (`AVAudioSession`, shared by the whole app). Oído,
/// dictation and reading aloud say what they use it for; `AudioSessionUses` decides the
/// configuration, so one finishing never deactivates the session under another. Nothing else in
/// the app sets the category or activates the session. On the Mac there is no session: no-ops.
enum AppAudioSession {
    private static let log = Logger(subsystem: "dev.happier.apple", category: "audio-session")
    /// Held across the session calls too: two holders changing at once must apply in order.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var uses = AudioSessionUses<ObjectIdentifier>()

    /// `holder` uses audio for `use` from now on: configures and activates the session.
    static func begin(_ use: AudioUse, by holder: AnyObject) throws {
        try lock.withLock {
            if case .activate(let plan) = uses.begin(use, by: ObjectIdentifier(holder)) { try apply(plan, activate: true) }
        }
    }

    /// Registers `holder` without touching the session yet (the microphone activates it when its
    /// engine starts, with `activate()`). Returns whether the configuration changed.
    @discardableResult
    static func hold(_ use: AudioUse, by holder: AnyObject) -> Bool {
        lock.withLock {
            let before = uses.plan
            _ = uses.begin(use, by: ObjectIdentifier(holder))
            return uses.plan != before
        }
    }

    /// Applies the current configuration and activates the session (again after a call took it).
    static func activate() throws {
        try lock.withLock {
            guard let plan = uses.plan else { return }
            try apply(plan, activate: true)
        }
    }

    /// `holder` is done. The last one deactivates the session, letting other apps' audio back up.
    static func end(by holder: AnyObject) {
        lock.withLock {
            switch uses.end(by: ObjectIdentifier(holder)) {
            case .activate(let plan):
                do { try apply(plan, activate: false) } catch {
                    log.error("audio session reconfiguration failed: \(String(describing: error), privacy: .public)")
                }
            case .deactivate:
                #if os(iOS)
                do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) } catch {
                    // Busy: something still plays (the silence keeping auto read alive); it ends with it.
                    log.notice("audio session deactivation: \(String(describing: error), privacy: .public)")
                }
                #endif
            case .keep:
                break
            }
        }
    }

    private static func apply(_ plan: AudioSessionPlan, activate: Bool) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = []
        if plan.options.contains(.mixWithOthers) { options.insert(.mixWithOthers) }
        if plan.options.contains(.duckOthers) { options.insert(.duckOthers) }
        if plan.options.contains(.defaultToSpeaker) { options.insert(.defaultToSpeaker) }
        if plan.options.contains(.allowBluetoothA2DP) { options.insert(.allowBluetoothA2DP) }
        // Play-and-record rather than record-only: record-only left the speech synthesizer mute
        // afterwards (reading aloud stopped working after the mic).
        try session.setCategory(plan.category == .playAndRecord ? .playAndRecord : .playback,
                                mode: plan.mode == .spokenAudio ? .spokenAudio : .default, options: options)
        // iOS otherwise mutes dictation's ready tone while the microphone is active.
        if plan.category == .playAndRecord { try session.setAllowHapticsAndSystemSoundsDuringRecording(true) }
        if activate { try session.setActive(true) }
        #endif
    }
}

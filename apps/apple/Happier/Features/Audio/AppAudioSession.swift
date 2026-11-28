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
            guard case .activate(let plan) = uses.begin(use, by: ObjectIdentifier(holder)) else { return }
            do { try apply(plan, activate: true) } catch {
                // Callers reading aloud go on without the session; say why sound may be missing.
                log.error("audio session for \(String(describing: use), privacy: .public) failed: \(String(describing: error), privacy: .public)")
                throw error
            }
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
                keepOffAirPlay(nil)
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
        _ = watchRoute
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = []
        if plan.options.contains(.mixWithOthers) { options.insert(.mixWithOthers) }
        if plan.options.contains(.duckOthers) { options.insert(.duckOthers) }
        if plan.options.contains(.defaultToSpeaker) { options.insert(.defaultToSpeaker) }
        if plan.options.contains(.allowBluetoothA2DP) { options.insert(.allowBluetoothA2DP) }
        // Play-and-record for everything, reading aloud included (`AudioSessionPlan`): it never
        // follows a TV picked for AirPlay. Record-only left the speech synthesizer mute afterwards.
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        // iOS otherwise mutes dictation's ready tone while the microphone is active.
        try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        if activate { try session.setActive(true) }
        keepOffAirPlay(plan)
        #endif
    }

    #if os(iOS)
    /// Whether Happier moved its output to the iPhone's speaker (`keepOffAirPlay`).
    nonisolated(unsafe) private static var overridden = false

    /// A mirrored screen still takes play-and-record to the TV: while Happier speaks or dictates
    /// (`AudioSessionPlan.staysOffAirPlay`) its sound and the microphone move to the iPhone, so the
    /// reply isn't heard on the TV and the microphone isn't tied to the TV's output. iOS drops the
    /// override at the next route change (`watchRoute` decides again then); it's undone when
    /// Happier is done speaking or dictating. Called with the lock held; `nil` when nothing plays.
    private static func keepOffAirPlay(_ plan: AudioSessionPlan?) {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        let onAirPlay = outputs.contains { $0.portType == .airPlay }
        let ports = outputs.map(\.portType.rawValue).joined(separator: ",")
        do {
            if plan?.staysOffAirPlay == true {
                guard onAirPlay else { return }
                try session.overrideOutputAudioPort(.speaker)
                overridden = true
                log.notice("output was AirPlay (\(ports, privacy: .public)): moved to the iPhone's speaker")
            } else if overridden {
                overridden = false
                try session.overrideOutputAudioPort(.none)
                log.notice("output back to the route the user chose")
            }
        } catch {
            log.error("audio output override failed on \(ports, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Mirroring that starts or headphones that come and go mid-reply: decide again. The notice is
    /// handed to a queue of its own rather than handled where it's posted, so the poster never
    /// waits on the lock (held across session calls). The override's own route change and
    /// Happier's category changes are already decided where they happen.
    private static let watchRoute: Void = {
        let queue = DispatchQueue(label: "dev.happier.audio-route")
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                               object: AVAudioSession.sharedInstance(), queue: nil) { note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            guard reason != .override, reason != .categoryChange else { return }
            queue.async {
                lock.withLock {
                    guard let plan = uses.plan else { return }
                    keepOffAirPlay(plan)
                }
            }
        }
    }()
    #endif
}

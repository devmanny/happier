import AVFoundation
import HappierKit
import os
#if os(iOS)
import UIKit
#endif

/// The app's one microphone: a single `AVAudioEngine` whose input feeds everyone listening at
/// once (Oído all day, a dictation take on top of it), so one stopping never stops the other, and
/// what's dictated also reaches Oído. It owns bringing the microphone back after a call, Siri,
/// another app or new hardware took it (`MicrophoneRecovery` decides when).
final class Microphone: @unchecked Sendable {
    static let shared = Microphone()

    /// One listener's hold on the microphone; give it back with `detach`.
    final class Tap: @unchecked Sendable {
        let use: AudioUse
        /// Each buffer in the input's own format, on the audio thread. Shared with every other
        /// listener: read it, don't keep or change it.
        fileprivate let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
        /// Whether the microphone is running, interrupted or waiting, on the microphone's queue.
        fileprivate let onPhase: @Sendable (MicrophoneRecovery.Phase) -> Void

        fileprivate init(use: AudioUse, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
                         onPhase: @escaping @Sendable (MicrophoneRecovery.Phase) -> Void) {
            self.use = use
            self.onBuffer = onBuffer
            self.onPhase = onPhase
        }
    }

    private static let log = Logger(subsystem: "dev.happier.apple", category: "microphone")
    /// Everything below is touched only on this queue (it blocks while audio starts: never the main thread).
    private let queue = DispatchQueue(label: "dev.happier.microphone", qos: .userInitiated)
    /// Read on the audio thread for every buffer.
    private let taps = OSAllocatedUnfairLock<[Tap]>(initialState: [])
    private var engine: AVAudioEngine?
    private var engineObserver: NSObjectProtocol?
    private var recovery = MicrophoneRecovery()
    private var lastError: Error?
    /// Bumped by every start and stop, so a retry scheduled earlier doesn't act on a newer state.
    private var generation = 0

    private init() {
        #if os(iOS)
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] note in
            let info = note.userInfo ?? [:]
            guard let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let resume = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) }
            Self.log.notice("audio interruption \(type == .began ? "began" : "ended", privacy: .public) (should resume: \(String(describing: resume), privacy: .public))")
            self?.post(type == .began ? .interruptionBegan : .interruptionEnded)
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            // Our own category changes report as route changes too; only new or lost hardware matters.
            guard reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else { return }
            self?.post(.routeChanged)
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
            Self.log.notice("media services were reset; rebuilding the microphone")
            self?.post(.servicesReset)
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.post(.becameActive)
        }
        #endif
    }

    /// Starts listening for `use`. A dictation take gets the microphone now or an error; Oído
    /// (`waitsForMicrophone`) always gets its tap, and the microphone comes to it once it's free
    /// (`onPhase` says when).
    func attach(_ use: AudioUse, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
                onPhase: @escaping @Sendable (MicrophoneRecovery.Phase) -> Void = { _ in }) async throws -> Tap {
        let tap = Tap(use: use, onBuffer: onBuffer, onPhase: onPhase)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                let changed = AppAudioSession.hold(use, by: tap)
                taps.withLock { $0.append(tap) }
                if recovery.phase == .running {
                    // Already listening for someone else (a take while Oído listens): nothing to
                    // restart. Oído joining a take switches the session to its mixing.
                    if changed {
                        do { try AppAudioSession.activate() } catch {
                            Self.log.error("audio session update failed: \(String(describing: error), privacy: .public)")
                        }
                    }
                    tap.onPhase(.running)
                    return continuation.resume()
                }
                let before = recovery.phase
                handle(.asked)
                if recovery.phase == .running || use.waitsForMicrophone {
                    // A change was already announced to every tap, this one included.
                    if recovery.phase == before { tap.onPhase(before) }
                    return continuation.resume()
                }
                let error = lastError ?? MicrophoneError.unavailable
                remove(tap)
                continuation.resume(throwing: error)
            }
        }
        return tap
    }

    /// Stops listening. No buffer reaches `tap` once this returns (but one already being handed
    /// out); the engine stops, and the session deactivates, when it was the last listener.
    func detach(_ tap: Tap) {
        let present = taps.withLock { list in
            let before = list.count
            list.removeAll { $0 === tap }
            return list.count != before
        }
        guard present else { return }
        queue.async { [self] in
            if taps.withLock({ $0.isEmpty }) { handle(.unwanted) }
            // After the engine stopped: an active engine keeps the session from deactivating.
            AppAudioSession.end(by: tap)
        }
    }

    // MARK: On the queue

    private func remove(_ tap: Tap) {
        taps.withLock { $0.removeAll { $0 === tap } }
        if taps.withLock({ $0.isEmpty }) { handle(.unwanted) }
        AppAudioSession.end(by: tap)
    }

    private func handle(_ event: MicrophoneRecovery.Event) {
        let before = recovery.phase
        let action = recovery.handle(event)
        switch action {
        case .none:
            break
        case .stop:
            stopEngine()
        case .start:
            do {
                try startEngine()
                lastError = nil
                _ = recovery.handle(.started)
            } catch {
                Self.log.error("microphone didn't start: \(String(describing: error), privacy: .public)")
                lastError = error
                stopEngine()
                if case .retry(let delay) = recovery.handle(.startFailed) { scheduleRetry(after: delay) }
            }
        case .retry(let delay):
            scheduleRetry(after: delay)
        }
        if recovery.phase != before {
            Self.log.notice("microphone \(String(describing: before), privacy: .public) → \(String(describing: self.recovery.phase), privacy: .public) on \(String(describing: event), privacy: .public)")
            let phase = recovery.phase
            for tap in taps.withLock({ $0 }) { tap.onPhase(phase) }
        }
    }

    private func scheduleRetry(after delay: Duration) {
        let current = generation
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.generation == current else { return }
            self.handle(.retryDue)
        }
    }

    private func startEngine() throws {
        stopEngine()
        generation += 1
        try AppAudioSession.activate()
        var engine = AVAudioEngine()
        // An input with no valid format (the audio route was still changing) would raise an
        // Objective-C exception in `installTap`, which Swift can't catch: check it, give the route
        // a moment once, then report it as unavailable.
        if !Self.hasUsableInput(engine.inputNode) {
            Thread.sleep(forTimeInterval: 0.25)
            engine = AVAudioEngine()
            guard Self.hasUsableInput(engine.inputNode) else { throw MicrophoneError.unavailable }
        }
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [taps] buffer, _ in
            for tap in taps.withLock({ $0 }) { tap.onBuffer(buffer) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        // The hardware changed (a headset, another input): the engine stops itself; start over
        // with the new format.
        let id = ObjectIdentifier(engine)
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.engineReconfigured(id)
        }
    }

    private func post(_ event: MicrophoneRecovery.Event) {
        queue.async { [self] in handle(event) }
    }

    private func engineReconfigured(_ id: ObjectIdentifier) {
        queue.async { [self] in
            // Only the running engine's: an old one's notice may arrive after it was replaced.
            guard let engine, ObjectIdentifier(engine) == id else { return }
            Self.log.notice("audio configuration changed; restarting the microphone")
            handle(.engineStopped)
        }
    }

    private func stopEngine() {
        generation += 1
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private static func hasUsableInput(_ input: AVAudioInputNode) -> Bool {
        let format = input.outputFormat(forBus: 0)
        return format.sampleRate > 0 && format.channelCount > 0
    }
}

enum MicrophoneError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        String(localized: "The microphone isn't available right now. Try again.")
    }
}

import Foundation

/// When the app's microphone should (re)start. Someone listening (Oído all day, a dictation take)
/// wants it running; calls, Siri, the keyboard's dictation and other apps take it away, the audio
/// hardware changes under it (AirPods), and iOS doesn't always say when it's free again. This
/// decides, from what happened, whether to start, stop or try again later.
///
/// - An interruption's end restarts it even without `shouldResume`: the user turned Oído on.
/// - While another app holds it (an interruption with no end yet) nothing retries on a timer,
///   which could take the microphone back from a voice note being recorded; coming back to the
///   app, a new route or a user action (dictating) tries again.
/// - A start that fails when nothing holds it is retried after 1, 2, 4… up to 30 seconds.
public struct MicrophoneRecovery: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Nobody wants the microphone.
        case off
        case starting
        case running
        /// A call or another app has it.
        case interrupted
        /// Free again but it didn't start; retrying on a timer.
        case waiting
    }

    public enum Event: Sendable, Equatable {
        /// Someone wants the microphone now (a listener attached, a dictation take).
        case asked
        /// The last listener left.
        case unwanted
        case started
        case startFailed
        case interruptionBegan
        /// Whether or not iOS says to resume.
        case interruptionEnded
        /// The engine stopped itself (the input or output hardware changed).
        case engineStopped
        case routeChanged
        /// Media services were reset: every audio object must be rebuilt.
        case servicesReset
        /// The app came back to the front.
        case becameActive
        case retryDue
    }

    public enum Action: Sendable, Equatable {
        case none
        /// Build a fresh engine and start it (tearing down what's left of the old one).
        case start
        case stop
        case retry(after: Duration)
    }

    public private(set) var phase: Phase = .off
    /// An interruption began and hasn't ended.
    private var held = false
    /// Failed starts since it last ran, for the backoff.
    private var failures = 0

    public init() {}

    public static func retryDelay(afterFailures failures: Int) -> Duration {
        .seconds(min(1 << min(max(failures - 1, 0), 5), 30))
    }

    public mutating func handle(_ event: Event) -> Action {
        switch event {
        case .unwanted:
            let wasOn = phase != .off
            phase = .off
            held = false
            failures = 0
            return wasOn ? .stop : .none
        case .started:
            guard phase != .off else { return .none }
            phase = .running
            held = false
            failures = 0
            return .none
        case .startFailed:
            guard phase != .off else { return .none }
            if held {
                phase = .interrupted
                return .none
            }
            failures += 1
            phase = .waiting
            return .retry(after: Self.retryDelay(afterFailures: failures))
        default:
            break
        }
        guard phase != .off || event == .asked else { return .none }
        switch event {
        case .asked:
            return phase == .running || phase == .starting ? .none : begin()
        case .interruptionBegan:
            phase = .interrupted
            held = true
            return .stop
        case .interruptionEnded:
            held = false
            return phase == .interrupted || phase == .waiting ? begin() : .none
        case .engineStopped:
            return phase == .running ? begin() : .none
        case .routeChanged:
            return phase == .waiting ? begin() : .none
        case .servicesReset:
            held = false
            return begin()
        case .becameActive:
            guard phase == .interrupted || phase == .waiting else { return .none }
            held = false
            return begin()
        case .retryDue:
            return phase == .waiting ? begin() : .none
        case .unwanted, .started, .startFailed:
            return .none
        }
    }

    private mutating func begin() -> Action {
        phase = .starting
        return .start
    }
}

import Testing
@testable import HappierKit

/// One audio session and one microphone for Oído, dictation and reading aloud: who holds the
/// session decides its configuration, one holder leaving never switches it off under another, and
/// the microphone comes back by itself after a call or another app took it.
@Suite struct MicrophoneSharingTests {
    private let listening = AudioSessionPlan(category: .playAndRecord, mode: .standard,
                                             options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
    private let dictating = AudioSessionPlan(category: .playAndRecord, mode: .standard,
                                             options: [.duckOthers, .defaultToSpeaker, .allowBluetoothA2DP])

    // MARK: Audio session holders

    @Test func dictationEndingKeepsTheSessionOidoIsListeningOn() {
        var uses = AudioSessionUses<Int>()
        #expect(uses.begin(.listening, by: 1) == .activate(listening))
        // Oído's mixing wins over dictation's ducking: changing it would mean deactivating the
        // session under Oído's recording.
        #expect(uses.begin(.dictating, by: 2) == .activate(listening))
        #expect(uses.end(by: 2) == .keep)
        #expect(uses.plan == listening)
    }

    @Test func theLastHolderLeavingDeactivates() {
        var uses = AudioSessionUses<Int>()
        _ = uses.begin(.dictating, by: 1)
        #expect(uses.end(by: 1) == .deactivate)
        #expect(uses.plan == nil)
        #expect(uses.end(by: 1) == .keep)
    }

    @Test func dictationAloneLowersOtherAudioAsBefore() {
        var uses = AudioSessionUses<Int>()
        #expect(uses.begin(.dictating, by: 1) == .activate(dictating))
        // Oído starting meanwhile: its mixing applies from now on.
        #expect(uses.begin(.listening, by: 2) == .activate(listening))
        #expect(uses.end(by: 2) == .activate(dictating))
    }

    @Test func readingAloudUsesTheRecordingSessionWhileOidoListens() {
        var uses = AudioSessionUses<Int>()
        _ = uses.begin(.listening, by: 1)
        #expect(uses.begin(.reading(ducksOthers: true), by: 2) == .activate(listening))
        #expect(uses.end(by: 2) == .keep)
        // Oído paused while reading: back to the reading session, not switched off.
        _ = uses.begin(.reading(ducksOthers: false), by: 2)
        #expect(uses.end(by: 1) == .activate(AudioSessionPlan(category: .playback, mode: .spokenAudio, options: [.mixWithOthers])))
    }

    @Test func readingAloneDucksOrMixesAsAsked() {
        var uses = AudioSessionUses<Int>()
        #expect(uses.begin(.reading(ducksOthers: true), by: 1)
            == .activate(AudioSessionPlan(category: .playback, mode: .spokenAudio, options: [.duckOthers])))
        // The same holder again replaces its use (auto read waiting between messages).
        #expect(uses.begin(.reading(ducksOthers: false), by: 1)
            == .activate(AudioSessionPlan(category: .playback, mode: .spokenAudio, options: [.mixWithOthers])))
        #expect(uses.end(by: 1) == .deactivate)
    }

    // MARK: Microphone recovery

    @Test func comesBackAfterACallEvenWithoutShouldResume() {
        var mic = MicrophoneRecovery()
        #expect(mic.handle(.asked) == .start)
        #expect(mic.phase == .starting)
        #expect(mic.handle(.started) == .none)
        #expect(mic.phase == .running)
        #expect(mic.handle(.interruptionBegan) == .stop)
        #expect(mic.phase == .interrupted)
        // Nothing retries on a timer while the other app holds the microphone.
        #expect(mic.handle(.retryDue) == .none)
        #expect(mic.handle(.interruptionEnded) == .start)
        #expect(mic.handle(.started) == .none)
        #expect(mic.phase == .running)
    }

    @Test func aBusyMicrophoneIsRetriedWithBackoff() {
        var mic = MicrophoneRecovery()
        _ = mic.handle(.asked)
        _ = mic.handle(.started)
        _ = mic.handle(.interruptionBegan)
        _ = mic.handle(.interruptionEnded)
        #expect(mic.handle(.startFailed) == .retry(after: .seconds(1)))
        #expect(mic.phase == .waiting)
        #expect(mic.handle(.retryDue) == .start)
        #expect(mic.handle(.startFailed) == .retry(after: .seconds(2)))
        _ = mic.handle(.retryDue)
        #expect(mic.handle(.startFailed) == .retry(after: .seconds(4)))
        for _ in 0..<6 {
            _ = mic.handle(.retryDue)
            _ = mic.handle(.startFailed)
        }
        _ = mic.handle(.retryDue)
        #expect(mic.handle(.startFailed) == .retry(after: .seconds(30)))
        // Once it runs, the next failure starts the backoff over.
        _ = mic.handle(.retryDue)
        _ = mic.handle(.started)
        _ = mic.handle(.engineStopped)
        #expect(mic.handle(.startFailed) == .retry(after: .seconds(1)))
    }

    @Test func anEngineThatStoppedItselfRestarts() {
        var mic = MicrophoneRecovery()
        _ = mic.handle(.asked)
        _ = mic.handle(.started)
        // AirPods connected: the engine stops itself on the new configuration.
        #expect(mic.handle(.engineStopped) == .start)
        _ = mic.handle(.started)
        // Media services reset: everything is rebuilt.
        #expect(mic.handle(.servicesReset) == .start)
        _ = mic.handle(.started)
        // A route change with the engine still running changes nothing.
        #expect(mic.handle(.routeChanged) == .none)
    }

    @Test func aConfigurationChangeDuringACallWaitsForTheCallToEnd() {
        var mic = MicrophoneRecovery()
        _ = mic.handle(.asked)
        _ = mic.handle(.started)
        _ = mic.handle(.interruptionBegan)
        #expect(mic.handle(.engineStopped) == .none)
        #expect(mic.handle(.routeChanged) == .none)
        #expect(mic.phase == .interrupted)
    }

    @Test func comingBackToTheAppTriesAgain() {
        var mic = MicrophoneRecovery()
        _ = mic.handle(.asked)
        _ = mic.handle(.started)
        _ = mic.handle(.interruptionBegan)
        // The other app never said it was done (no interruption end): opening Happier retries.
        #expect(mic.handle(.becameActive) == .start)
        // Still taken (a call going on): from now on retried on a timer.
        #expect(mic.handle(.startFailed) == .retry(after: .seconds(1)))
        // A new route while waiting (a headset) is worth a try at once.
        #expect(mic.handle(.routeChanged) == .start)
    }

    @Test func dictatingDuringACallTriesOnceWithoutStartingTheTimer() {
        var mic = MicrophoneRecovery()
        _ = mic.handle(.asked)
        _ = mic.handle(.started)
        _ = mic.handle(.interruptionBegan)
        #expect(mic.handle(.asked) == .start)
        #expect(mic.handle(.startFailed) == .none)
        #expect(mic.phase == .interrupted)
        #expect(mic.handle(.interruptionEnded) == .start)
    }

    @Test func nobodyListeningStopsAndIgnoresLaterEvents() {
        var mic = MicrophoneRecovery()
        _ = mic.handle(.asked)
        _ = mic.handle(.started)
        _ = mic.handle(.interruptionBegan)
        #expect(mic.handle(.unwanted) == .stop)
        #expect(mic.phase == .off)
        #expect(mic.handle(.interruptionEnded) == .none)
        #expect(mic.handle(.becameActive) == .none)
        #expect(mic.handle(.engineStopped) == .none)
        #expect(mic.handle(.retryDue) == .none)
        #expect(mic.handle(.unwanted) == .none)
        // A start that failed after everyone left asks for nothing more.
        #expect(mic.handle(.startFailed) == .none)
        #expect(mic.phase == .off)
    }

    @Test func askingWhileRunningChangesNothing() {
        var mic = MicrophoneRecovery()
        _ = mic.handle(.asked)
        _ = mic.handle(.started)
        #expect(mic.handle(.asked) == .none)
        #expect(mic.phase == .running)
    }
}

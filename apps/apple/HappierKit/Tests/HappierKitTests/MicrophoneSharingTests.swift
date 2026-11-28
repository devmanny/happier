import Testing
@testable import HappierKit

/// One audio session and one microphone for Oído, dictation and reading aloud: who holds the
/// session decides its configuration, one holder leaving never switches it off under another, and
/// the microphone comes back by itself after a call or another app took it.
@Suite struct MicrophoneSharingTests {
    private let listening = AudioSessionPlan(options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP], staysOffAirPlay: false)
    private let dictating = AudioSessionPlan(options: [.duckOthers, .defaultToSpeaker, .allowBluetoothA2DP], staysOffAirPlay: true)
    /// Happier speaking or dictating over music it leaves at full volume.
    private let mixingOwnSound = AudioSessionPlan(options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP], staysOffAirPlay: true)

    // MARK: Audio session holders

    @Test func dictationEndingKeepsTheSessionOidoIsListeningOn() {
        var uses = AudioSessionUses<Int>()
        #expect(uses.begin(.listening, by: 1) == .activate(listening))
        // Oído's mixing wins over dictation's ducking: changing it would mean deactivating the
        // session under Oído's recording.
        #expect(uses.begin(.dictating, by: 2) == .activate(mixingOwnSound))
        #expect(uses.end(by: 2) == .activate(listening))
        #expect(uses.plan == listening)
    }

    @Test func theKeyboardsStandbyKeepsTheMicrophoneWithoutLoweringOtherAudio() {
        var uses = AudioSessionUses<Int>()
        // The app opened from the dictation keyboard keeps the microphone on for minutes in the
        // background: music keeps playing, and a take on top of it doesn't reconfigure the session
        // (in the background it couldn't be activated again).
        #expect(uses.begin(.standby, by: 1) == .activate(listening))
        #expect(uses.begin(.dictating, by: 2) == .activate(mixingOwnSound))
        #expect(uses.end(by: 2) == .activate(listening))
        #expect(uses.end(by: 1) == .deactivate)
        #expect(AudioUse.standby.records)
        #expect(!AudioUse.standby.waitsForMicrophone)
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
        #expect(uses.begin(.listening, by: 2) == .activate(mixingOwnSound))
        #expect(uses.end(by: 2) == .activate(dictating))
    }

    @Test func readingAloudUsesTheRecordingSessionWhileOidoListens() {
        var uses = AudioSessionUses<Int>()
        _ = uses.begin(.listening, by: 1)
        #expect(uses.begin(.reading(ducksOthers: true), by: 2) == .activate(mixingOwnSound))
        #expect(uses.end(by: 2) == .activate(listening))
        // Oído paused while reading: the same session goes on, not switched off.
        _ = uses.begin(.reading(ducksOthers: false), by: 2)
        #expect(uses.end(by: 1) == .keep)
        #expect(uses.plan == mixingOwnSound)
    }

    @Test func readingAloneDucksOrMixesAsAsked() {
        var uses = AudioSessionUses<Int>()
        let ducking = AudioSessionPlan(options: [.duckOthers, .defaultToSpeaker, .allowBluetoothA2DP], staysOffAirPlay: true)
        #expect(uses.begin(.reading(ducksOthers: true), by: 1) == .activate(ducking))
        // The same holder again replaces its use (auto read waiting between messages).
        #expect(uses.begin(.reading(ducksOthers: false), by: 1) == .activate(mixingOwnSound))
        #expect(uses.end(by: 1) == .deactivate)
    }

    @Test func spokenRepliesPlayThroughTheSessionThatNeverFollowsATV() {
        // Playback follows AirPlay to a TV by itself; play-and-record reaches it only with an
        // option Happier never sets. So reading aloud shares the microphone's session: alone,
        // with Oído, and across a dictation take, whose start then doesn't move the route.
        #expect(AudioSessionPlan.resolve([.reading(ducksOthers: false)]) == mixingOwnSound)
        #expect(AudioSessionPlan.resolve([.reading(ducksOthers: false), .listening]) == mixingOwnSound)
        #expect(AudioSessionPlan.resolve([.reading(ducksOthers: false), .dictating]) == mixingOwnSound)
    }

    @Test func dictatingWhileAutoReadWaitsNeverLeavesMusicLowered() {
        var uses = AudioSessionUses<Int>()
        // Auto read holds the session between messages; iOS raises other audio again only when
        // the session ends. A take lowering music on top of it would leave it lowered for as
        // long as auto read stays on, so the take mixes.
        #expect(uses.begin(.reading(ducksOthers: false), by: 1) == .activate(mixingOwnSound))
        #expect(uses.begin(.dictating, by: 2) == .activate(mixingOwnSound))
        #expect(uses.end(by: 2) == .keep)
        #expect(uses.plan == mixingOwnSound)
    }

    @Test func onlyHappiersOwnSoundIsPulledOffAMirroredTV() {
        // Speaking or dictating: the sound and the microphone come back to the iPhone when a
        // mirrored screen took the route. Oído or the keyboard's standby alone leave it alone.
        #expect(AudioSessionPlan.resolve([.listening])?.staysOffAirPlay == false)
        #expect(AudioSessionPlan.resolve([.standby])?.staysOffAirPlay == false)
        #expect(AudioSessionPlan.resolve([.standby, .dictating])?.staysOffAirPlay == true)
        #expect(AudioSessionPlan.resolve([.listening, .reading(ducksOthers: true)])?.staysOffAirPlay == true)
        #expect(AudioSessionPlan.resolve([.dictating])?.staysOffAirPlay == true)
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

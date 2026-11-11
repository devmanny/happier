import Testing
@testable import HappierKit

/// Which speech-to-text engine dictation uses on this device.
struct DictationEngineTests {
    /// What WhisperKit's device table lists for an iPhone 16 Pro (iPhone17,1).
    private let iPhone16Pro = ["openai_whisper-small", "openai_whisper-small.en",
                               "openai_whisper-large-v3-v20240930_626MB", "openai_whisper-large-v3-v20240930_turbo_632MB"]
    /// And for an iPhone 12 (iPhone13,x): small only, which dictation doesn't offer.
    private let iPhone12 = ["openai_whisper-small", "openai_whisper-small.en"]

    @Test func whisperOnceItsModelIsDownloaded() async {
        var askedApple = false
        #expect(await DictationEngine.choose(installed: .largeV3Turbo, deviceSupports: iPhone16Pro,
                                             speechTranscriber: { askedApple = true; return true }) == .whisper(.largeV3Turbo))
        // Apple's availability isn't looked up (it delays the take) when Whisper dictates.
        #expect(!askedApple)
    }

    @Test func appleSpeechUntilAModelIsDownloaded() async {
        #expect(await DictationEngine.choose(installed: nil, deviceSupports: iPhone16Pro, speechTranscriber: { true }) == .speechTranscriber)
        #expect(await DictationEngine.choose(installed: nil, deviceSupports: iPhone16Pro, speechTranscriber: { false }) == .speechRecognizer)
    }

    @Test func appleSpeechWhenTheDeviceCannotRunTheModel() async {
        #expect(await DictationEngine.choose(installed: .largeV3Turbo, deviceSupports: iPhone12, speechTranscriber: { true }) == .speechTranscriber)
        #expect(await DictationEngine.choose(installed: .largeV3Turbo, deviceSupports: iPhone12, speechTranscriber: { false }) == .speechRecognizer)
    }

    @Test func aDeviceRunsOnlyTheModelsItsTableLists() {
        #expect(WhisperModel.largeV3Turbo.runs(onDeviceSupporting: iPhone16Pro))
        #expect(!WhisperModel.largeV3Turbo.runs(onDeviceSupporting: iPhone12))
        #expect(!WhisperModel.largeV3Turbo.runs(onDeviceSupporting: []))
    }

    // MARK: Each take

    @Test func appleDictatesWhileWhisperLoads() async {
        let take = await DictationEngine.forTake(.whisper(.largeV3Turbo), whisperLoaded: false, appleAllowed: true) { true }
        #expect(take == DictationTake(engine: .speechTranscriber, fallback: .whisperNotLoaded))
        let classic = await DictationEngine.forTake(.whisper(.largeV3Turbo), whisperLoaded: false, appleAllowed: true) { false }
        #expect(classic == DictationTake(engine: .speechRecognizer, fallback: .whisperNotLoaded))
    }

    @Test func whisperDictatesOnceLoaded() async {
        var askedApple = false
        let take = await DictationEngine.forTake(.whisper(.largeV3Turbo), whisperLoaded: true, appleAllowed: true) {
            askedApple = true
            return true
        }
        #expect(take == DictationTake(engine: .whisper(.largeV3Turbo), fallback: nil))
        #expect(!askedApple)
    }

    @Test func whisperWaitsForItsModelWhenAppleSpeechIsNotAllowed() async {
        // Whisper asks only for the microphone: without speech recognition allowed, there is no
        // Apple engine to hand the take to, so it waits for Whisper.
        let take = await DictationEngine.forTake(.whisper(.largeV3Turbo), whisperLoaded: false, appleAllowed: false) { true }
        #expect(take == DictationTake(engine: .whisper(.largeV3Turbo), fallback: nil))
    }

    @Test func appleEnginesAreUsedAsChosen() async {
        #expect(await DictationEngine.forTake(.speechTranscriber, whisperLoaded: false, appleAllowed: true) { false }
            == DictationTake(engine: .speechTranscriber, fallback: nil))
    }
}

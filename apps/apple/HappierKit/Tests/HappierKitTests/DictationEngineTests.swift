import Testing
@testable import HappierKit

/// Which speech-to-text engine dictation uses on this device.
struct DictationEngineTests {
    /// What WhisperKit 1.1.1's device table lists for an iPhone 16 Pro (iPhone17,1: the A16, A17 Pro
    /// and A18 entry of `Constants.fallbackModelSupportConfig`).
    private let iPhone16Pro = ["openai_whisper-tiny", "openai_whisper-tiny.en", "openai_whisper-base", "openai_whisper-base.en",
                               "openai_whisper-small", "openai_whisper-small.en", "openai_whisper-large-v2_949MB",
                               "openai_whisper-large-v2_turbo_955MB", "openai_whisper-large-v3_947MB", "openai_whisper-large-v3_turbo_954MB",
                               "distil-whisper_distil-large-v3_594MB", "distil-whisper_distil-large-v3_turbo_600MB",
                               "openai_whisper-large-v3-v20240930_626MB", "openai_whisper-large-v3-v20240930_turbo_632MB"]
    /// And for an iPhone 12 (iPhone13,x, A14): the small models only.
    private let iPhone12 = ["openai_whisper-tiny", "openai_whisper-tiny.en", "openai_whisper-base", "openai_whisper-base.en",
                            "openai_whisper-small", "openai_whisper-small.en"]

    @Test func whisperOnceItsModelIsDownloaded() async {
        var askedApple = false
        #expect(await DictationEngine.choose(inUse: .largeV3Turbo, deviceSupports: iPhone16Pro,
                                             speechTranscriber: { askedApple = true; return true }) == .whisper(.largeV3Turbo))
        // Apple's availability isn't looked up (it delays the take) when Whisper dictates.
        #expect(!askedApple)
    }

    @Test func appleSpeechUntilAModelIsDownloaded() async {
        #expect(await DictationEngine.choose(inUse: nil, deviceSupports: iPhone16Pro, speechTranscriber: { true }) == .speechTranscriber)
        #expect(await DictationEngine.choose(inUse: nil, deviceSupports: iPhone16Pro, speechTranscriber: { false }) == .speechRecognizer)
    }

    @Test func appleSpeechWhenTheDeviceCannotRunTheModel() async {
        #expect(await DictationEngine.choose(inUse: .largeV3Turbo, deviceSupports: iPhone12, speechTranscriber: { true }) == .speechTranscriber)
        #expect(await DictationEngine.choose(inUse: .largeV3Turbo, deviceSupports: iPhone12, speechTranscriber: { false }) == .speechRecognizer)
    }

    @Test func aDeviceRunsOnlyTheModelsItsTableLists() {
        #expect(WhisperModel.largeV3Turbo.runs(onDeviceSupporting: iPhone16Pro))
        #expect(!WhisperModel.largeV3Turbo.runs(onDeviceSupporting: iPhone12))
        #expect(!WhisperModel.largeV3Turbo.runs(onDeviceSupporting: []))
    }

    @Test func aLighterModelDictatesWhereTurboCannot() async {
        #expect(await DictationEngine.choose(inUse: .small, deviceSupports: iPhone12, speechTranscriber: { true }) == .whisper(.small))
        #expect(await DictationEngine.choose(inUse: .tiny, deviceSupports: iPhone16Pro, speechTranscriber: { true }) == .whisper(.tiny))
    }

    @Test func theCatalogIsMultilingualModelsAnIPhoneRuns() {
        // Dictation is in the user's language: English-only (.en) models don't belong.
        for model in WhisperModel.allCases {
            #expect(model.runs(onDeviceSupporting: iPhone16Pro), "\(model.id)")
            #expect(!model.id.hasSuffix(".en"))
        }
        #expect(WhisperModel.allCases.count > 1)
        #expect(WhisperModel.recommended.runs(onDeviceSupporting: iPhone16Pro))
        // WhisperKit downloads by variant: "tiny" must not also match "tiny.en".
        #expect(WhisperModel.tiny.variant == "tiny")
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

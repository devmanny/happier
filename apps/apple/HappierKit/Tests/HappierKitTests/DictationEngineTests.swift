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
}

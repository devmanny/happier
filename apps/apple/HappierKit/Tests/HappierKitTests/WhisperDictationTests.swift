import Testing
@testable import HappierKit

/// Live Whisper dictation: what gets transcribed, and how its passes add up to one text.
struct WhisperDictationTests {
    /// 100 ms loudness frames (dBFS) of a take.
    private func frames(_ parts: [(dB: Float, count: Int)]) -> [Float] {
        parts.flatMap { Array(repeating: $0.dB, count: $0.count) }
    }

    @Test func speechEndsShortlyAfterTheLastWords() {
        // 1 s of room noise, 2 s of speech, 3 s of room noise after letting go.
        let take = frames([(-62, 10), (-30, 20), (-62, 30)])
        // The last loud frame ends at 3.0 s; a 0.4 s margin keeps the word's tail.
        #expect(DictationSpeech.speechEnd(frameLevels: take) == 34)
    }

    @Test func silenceHasNoSpeech() {
        // Whisper writes "Gracias." for silence: a take with no speech is not transcribed.
        #expect(DictationSpeech.speechEnd(frameLevels: frames([(-62, 40)])) == nil)
        #expect(DictationSpeech.speechEnd(frameLevels: []) == nil)
    }

    @Test func quietSpeechStillCounts() {
        // A soft voice far from the microphone: loud only relative to the room.
        let take = frames([(-70, 10), (-50, 20), (-70, 10)])
        #expect(DictationSpeech.speechEnd(frameLevels: take) == 34)
    }

    private func segment(_ text: String, _ start: Float, _ end: Float) -> WhisperStreamTranscript.Segment {
        .init(text: text, start: start, end: end)
    }

    @Test func confirmsAllButTheLastTwoSegments() {
        var transcript = WhisperStreamTranscript()
        transcript.update([segment(" Hola,", 0, 1), segment(" revisa la sesión", 1, 3)], final: false)
        #expect(transcript.text == "Hola, revisa la sesión")
        #expect(transcript.confirmedEnd == 0)

        // The next pass reads from 0 again and still has the first segment: it is now settled.
        transcript.update([segment(" Hola,", 0, 1), segment(" revisa la sesión", 1, 3), segment(" de Radar", 3, 4)], final: false)
        #expect(transcript.confirmedEnd == 1)
        #expect(transcript.text == "Hola, revisa la sesión de Radar")

        // Later passes start at the confirmed end, so they report only what follows it.
        transcript.update([segment(" revisa la sesión de Radar", 1, 4), segment(" y avísame", 4, 5)], final: false)
        #expect(transcript.text == "Hola, revisa la sesión de Radar y avísame")
    }

    @Test func theFinalPassConfirmsEverything() {
        var transcript = WhisperStreamTranscript()
        transcript.update([segment(" Hola,", 0, 1), segment(" revisa", 1, 2), segment(" la sesión", 2, 3)], final: false)
        transcript.update([segment(" revisa la sesión", 1, 3), segment(" de Radar.", 3, 4)], final: true)
        #expect(transcript.text == "Hola, revisa la sesión de Radar.")
    }
}

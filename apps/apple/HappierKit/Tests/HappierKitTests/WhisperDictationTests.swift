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

    // MARK: Passes WhisperKit decodes, and text that never blanks

    /// WhisperKit starts no window in a clip's last `windowClipTime` (1 s by default,
    /// TranscribeTask.swift:113): a clip that short comes back with no segments at all.
    private let windowClipTime: Float = 1

    @Test func aShortTakeIsLongEnoughToDecode() {
        // "Sí." and let go: the speech ends 0.9 s into the take.
        var transcript = WhisperStreamTranscript()
        let pass = transcript.pass(speechEnd: 0.9, minimumLength: windowClipTime)
        #expect(pass?.start == 0)
        #expect(pass.map { $0.end > $0.start + windowClipTime } == true)
        // A longer take is read up to the end of its speech, no further.
        #expect(transcript.pass(speechEnd: 5, minimumLength: windowClipTime)?.end == 5)
    }

    @Test func aPassThatDecodesNothingKeepsTheWordsShown() {
        var transcript = WhisperStreamTranscript()
        transcript.update([segment(" Hola,", 0, 1), segment(" revisa la sesión", 1, 3)], final: false)
        // Whisper judged this window silent: the composer must not go blank and come back.
        transcript.update([], final: false)
        #expect(transcript.text == "Hola, revisa la sesión")
        transcript.update([segment(" ", 3, 3.2)], final: false)
        #expect(transcript.text == "Hola, revisa la sesión")
    }

    @Test func theLastWordsSurviveAFinalPassThatDecodesNothing() {
        var transcript = WhisperStreamTranscript()
        transcript.update([segment(" Hola,", 0, 1), segment(" revisa la sesión", 1, 3), segment(" de Radar.", 3, 4)], final: false)
        transcript.update([], final: true)
        #expect(transcript.text == "Hola, revisa la sesión de Radar.")
    }

    @Test func aTailTooShortToDecodeReopensTheWordsBeforeIt() {
        var transcript = WhisperStreamTranscript()
        // Confirms "Hola," and "revisa la sesión" (to 3 s); "de Radar" and "ya" stay open.
        transcript.update([segment(" Hola,", 0, 1), segment(" revisa la sesión", 1, 3),
                           segment(" de Radar", 3, 3.5), segment(" ya", 3.5, 3.7)], final: false)
        #expect(transcript.confirmedEnd == 3)
        // Let go at once: the speech ends 0.8 s past the confirmed words, too short to decode alone.
        let pass = transcript.pass(speechEnd: 3.8, minimumLength: windowClipTime)
        #expect(pass?.start == 1)
        #expect(transcript.text == "Hola, revisa la sesión de Radar ya")
        // That pass reads again from 1 s: its words replace the reopened ones, once.
        transcript.update([segment(" revisa la sesión", 1, 3), segment(" de Radar ya.", 3, 3.8)], final: true)
        #expect(transcript.text == "Hola, revisa la sesión de Radar ya.")
    }

    @Test func noPassUntilSomethingIsSaidAfterTheConfirmedWords() {
        var transcript = WhisperStreamTranscript()
        transcript.update([segment(" Hola,", 0, 1), segment(" revisa", 1, 2), segment(" la sesión", 2, 3)], final: false)
        #expect(transcript.confirmedEnd == 1)
        #expect(transcript.pass(speechEnd: 1, minimumLength: windowClipTime) == nil)
        #expect(transcript.pass(speechEnd: 2.5, minimumLength: windowClipTime) == .init(start: 1, end: 2.5))
    }
}

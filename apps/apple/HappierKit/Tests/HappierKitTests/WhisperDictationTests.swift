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

    @Test func aShortNoiseIsNotSpeech() {
        // A tap or a rustle (0.2 s) after the words: Whisper hears "Gracias." in it, so it isn't
        // speech and the take's speech still ends with the words.
        let take = frames([(-62, 10), (-30, 20), (-62, 20), (-30, 2), (-62, 20)])
        #expect(DictationSpeech.speechEnd(frameLevels: take) == 34)
        // Nothing but taps: no speech at all.
        #expect(DictationSpeech.speechEnd(frameLevels: frames([(-62, 20), (-30, 2), (-62, 20), (-30, 1), (-62, 20)])) == nil)
    }

    @Test func aShortWordIsSpeech() {
        // "Sí" or "no": 0.3 s.
        #expect(DictationSpeech.speechEnd(frameLevels: frames([(-62, 10), (-30, 3), (-62, 10)])) == 17)
    }

    @Test func speechCountsOnlySustainedSound() {
        let take = frames([(-62, 10), (-30, 6), (-62, 10), (-30, 2), (-62, 10)])
        #expect(DictationSpeech.speechSeconds(frameLevels: take, from: 0) == 0.6)
        // After the words: only the tap, which isn't speech.
        #expect(DictationSpeech.speechSeconds(frameLevels: take, from: 16) == 0)
    }

    @Test func speakingAtOnceIsSpeechFromTheFirstWords() {
        // Talking the moment the mic opens: a second of words with no quiet before them. The
        // take's quietest tenth is the voice itself, yet it is speech, and live passes start.
        let take = frames([(-28, 2), (-24, 3), (-32, 1), (-26, 2), (-30, 2)])
        #expect(DictationSpeech.speechEnd(frameLevels: take) == 10)
        #expect(DictationSpeech.speechSeconds(frameLevels: take, from: 0) == 1)
    }

    @Test func aLoudButSteadyRoomIsNotSpeech() {
        // A car or a café: steady noise, louder than a quiet room, with nothing said.
        #expect(DictationSpeech.speechEnd(frameLevels: frames([(-45, 40)])) == nil)
        // Words over it still count, after it and from the first instant alike.
        #expect(DictationSpeech.speechEnd(frameLevels: frames([(-45, 10), (-28, 20), (-45, 20)])) == 34)
        #expect(DictationSpeech.speechEnd(frameLevels: frames([(-28, 20), (-45, 20)])) == 24)
    }

    @Test func quietSpeechStillCounts() {
        // A soft voice far from the microphone: loud only relative to the room.
        let take = frames([(-70, 10), (-50, 20), (-70, 10)])
        #expect(DictationSpeech.speechEnd(frameLevels: take) == 34)
    }

    private func segment(_ text: String, _ start: Float, _ end: Float) -> WhisperStreamTranscript.Segment {
        .init(text: text, start: start, end: end)
    }

    @Test func whispersWordsForSilenceAreDroppedWhenAlmostNothingWasSaid() {
        var transcript = WhisperStreamTranscript()
        transcript.update([segment(" Busca una Mac Studio.", 0, 2)], final: false, speech: 2)
        // A noise long enough to pass: what Whisper writes for silence isn't kept.
        transcript.update([segment(" Busca una Mac Studio.", 0, 2), segment(" Gracias.", 2, 3)], final: false, speech: 0.3)
        #expect(transcript.text == "Busca una Mac Studio.")
        transcript.update([segment(" Busca una Mac Studio.", 0, 2), segment(" ¡Gracias por ver el video!", 2, 3)], final: true, speech: 0.3)
        #expect(transcript.text == "Busca una Mac Studio.")
        #expect(WhisperStreamTranscript.isSilencePhrase(" Subtítulos realizados por la comunidad de Amara.org"))
    }

    @Test func aSegmentWithoutWordsIsDropped() {
        // A breath or a noise before speaking: Whisper writes "." or "..." for it, and the take
        // started with ". pero pues acá hay…".
        var transcript = WhisperStreamTranscript()
        transcript.update([segment(" .", 0, 0.8), segment(" Pero pues acá hay marcas de lujo", 0.8, 3), segment(" y restaurantes caros.", 3, 4.5)], final: true)
        #expect(transcript.text == "Pero pues acá hay marcas de lujo y restaurantes caros.")
        var dots = WhisperStreamTranscript()
        dots.update([segment(" ...", 0, 1), segment(" -", 1, 2)], final: true)
        #expect(dots.text == "")
        // Numbers are words.
        var number = WhisperStreamTranscript()
        number.update([segment(" 25.", 0, 1)], final: true)
        #expect(number.text == "25.")
    }

    @Test func aRealThankYouIsKept() {
        var transcript = WhisperStreamTranscript()
        // "Gracias" said for real lasts half a second or more.
        transcript.update([segment(" Muchas gracias.", 0, 1)], final: true, speech: 0.8)
        #expect(transcript.text == "Muchas gracias.")
        // Any other words are kept however short.
        var short = WhisperStreamTranscript()
        short.update([segment(" No.", 0, 1)], final: true, speech: 0.3)
        #expect(short.text == "No.")
    }

    @Test func aPassThatStartsMidSentenceKeepsTheSentencesCase() {
        // Each pass is decoded on its own, so Whisper starts it as a sentence: "Lo que vas diciendo".
        // The words at that point were decoded before in context ("lo que"), and keep that case.
        var transcript = WhisperStreamTranscript()
        transcript.update([segment(" Porque te va dibujando", 0, 1.5), segment(" lo que vas diciendo", 1.5, 3),
                           segment(" de ahí", 3, 4)], final: false)
        transcript.update([segment(" Lo que vas diciendo,", 1.5, 3), segment(" de ahí en más", 3, 4.2),
                           segment(" creo que", 4.2, 5)], final: false)
        transcript.update([segment(" De ahí en más", 3, 4.2), segment(" Creo que Fireflies o las notas de Gemini son iguales.", 4.2, 7)], final: true)
        #expect(transcript.text == "Porque te va dibujando lo que vas diciendo, de ahí en más creo que Fireflies o las notas de Gemini son iguales.")
    }

    @Test func aPassAfterASentenceOrANameKeepsItsCapital() {
        var transcript = WhisperStreamTranscript()
        transcript.update([segment(" Ya llegué.", 0, 1), segment(" Gemini lo resume", 1, 2), segment(" bien", 2, 3)], final: false)
        transcript.update([segment(" Gemini lo resume", 1, 2), segment(" bien.", 2, 3)], final: true)
        #expect(transcript.text == "Ya llegué. Gemini lo resume bien.")
    }

    @Test func aSpanishYesIsNotTheLetterC() {
        // Whisper hears a lone "sí" as the letter "C." (3 of 4 voices tried).
        var transcript = WhisperStreamTranscript(language: "es")
        transcript.update([segment(" C.", 0, 1)], final: true)
        #expect(transcript.text == "Sí.")
        var question = WhisperStreamTranscript(language: "es")
        question.update([segment(" ¿C?", 0, 1)], final: true)
        #expect(question.text == "¿Sí?")
        // Not in English, and not a C inside other words.
        var english = WhisperStreamTranscript(language: "en")
        english.update([segment(" C.", 0, 1)], final: true)
        #expect(english.text == "C.")
        var vitamin = WhisperStreamTranscript(language: "es")
        vitamin.update([segment(" Vitamina C.", 0, 1)], final: true)
        #expect(vitamin.text == "Vitamina C.")
        // Automatic: the language Whisper recognized in the take.
        var heard = WhisperStreamTranscript()
        heard.language = "es"
        heard.update([segment(" C.", 0, 1)], final: true)
        #expect(heard.text == "Sí.")
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

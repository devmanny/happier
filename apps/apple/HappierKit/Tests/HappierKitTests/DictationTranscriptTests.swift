import Testing
@testable import HappierKit

/// Live dictation: the speech recognizer starts a new utterance after a pause and from then on
/// reports only the new words, so what was said before the pause must be kept, not replaced.
struct DictationTranscriptTests {
    @Test func growsWithinOneUtterance() {
        var transcript = DictationTranscript()
        transcript.update("Hola")
        transcript.update("Hola cómo")
        transcript.update("Hola cómo estás")
        #expect(transcript.text == "Hola cómo estás")
    }

    @Test func keepsWhatWasSaidBeforeAPause() {
        var transcript = DictationTranscript()
        transcript.update("Revisa la sesión")
        transcript.update("Revisa la sesión de Radar", endsUtterance: true)
        transcript.update("Y")
        transcript.update("Y luego avísame")
        #expect(transcript.text == "Revisa la sesión de Radar Y luego avísame")
    }

    @Test func keepsItWhenThePauseIsNotFlagged() {
        var transcript = DictationTranscript()
        transcript.update("Revisa la sesión de Radar por favor")
        transcript.update("Luego")
        transcript.update("Luego avísame")
        #expect(transcript.text == "Revisa la sesión de Radar por favor Luego avísame")
    }

    @Test func doesNotRepeatAnUtteranceTheRecognizerKeepsReporting() {
        var transcript = DictationTranscript()
        transcript.update("Revisa la sesión", endsUtterance: true)
        transcript.update("Revisa la sesión y avísame")
        #expect(transcript.text == "Revisa la sesión y avísame")
    }

    @Test func aCorrectionIsNotANewUtterance() {
        var transcript = DictationTranscript()
        transcript.update("I")
        transcript.update("Hi there")
        transcript.update("Hi there how are you")
        transcript.update("Hi there, how are you?")
        #expect(transcript.text == "Hi there, how are you?")
    }
}

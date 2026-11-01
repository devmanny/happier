import Testing
@testable import HappierKit

/// The app's own text is English only, so the system reports English as its language even on a
/// Spanish phone; dictation and reading aloud go by the user's languages instead.
@Suite struct SpeechLanguageTests {
    @Test func readingDoesNotSwitchShortSpanishMessagesToPortuguese() {
        // The unrestricted Apple recognizer identifies these as Portuguese on macOS 26.
        // Exercise the actual recognizer, including English as the device's first language.
        for text in ["Claro", "Lista", "Para importar cookies"] {
            #expect(SpeechLanguage.readingLanguage(for: text, allowed: ["en", "es"]) == "es")
        }
        #expect(SpeechLanguage.readingLanguage(for: "The changes are ready for review.", allowed: ["es", "en"]) == "en")
        #expect(SpeechLanguage.readingLanguage(for: "The changes are ready for review.", allowed: ["es"]) == "es")
        #expect(SpeechLanguage.readingLanguage(for: "", allowed: ["es", "en"]) == "es")
        // Voice languages are grouped by base code, but Apple's Chinese detector uses scripts.
        #expect(SpeechLanguage.readingLanguage(for: "这是一个中文消息。现在可以阅读你的消息。", allowed: ["es", "zh"]) == "zh")
    }

    @Test func readingLanguagesFollowTheExplicitChoiceOrDevicePreferences() {
        #expect(SpeechLanguage.readingLanguages(preferred: ["en-MX", "es-MX", "es-ES"]) == ["en", "es"])
        #expect(SpeechLanguage.readingLanguages(preferred: ["en-MX"], chosen: ["es-MX", "en-US", "es"]) == ["es", "en"])
        #expect(SpeechLanguage.readingLanguages(preferred: [], chosen: []) == ["en"])
    }

    @Test func dictationListensInTheUsersOwnLanguage() {
        let supported = ["en-US", "en-GB", "es-ES", "es-MX", "es-US", "fr-FR"]
        #expect(SpeechLanguage.dictationLocale(preferred: ["es-MX", "en-MX"], region: "MX", supported: supported) == "es-MX")
        // Latin American Spanish isn't a recognizer of its own: the user's region decides.
        #expect(SpeechLanguage.dictationLocale(preferred: ["es-419"], region: "MX", supported: supported) == "es-MX")
        #expect(SpeechLanguage.dictationLocale(preferred: ["es"], region: "AR", supported: supported) == "es-ES")
        #expect(SpeechLanguage.dictationLocale(preferred: ["eo", "fr-CA"], region: "CA", supported: supported) == "fr-FR")
        #expect(SpeechLanguage.dictationLocale(preferred: ["eo"], region: nil, supported: supported) == nil)
    }

    /// Left alone, it reads with the system's own voice for the language unless a more natural
    /// (Enhanced or Premium) one is installed; never with the old Eloquence synthesizers.
    @Test func readsWithTheMostNaturalVoiceInstalledUnlessOneWasChosen() {
        let basic = [
            SpeechLanguage.Voice(id: "com.apple.voice.compact.es-ES.Monica", name: "Mónica", language: "es-ES", quality: 0),
            SpeechLanguage.Voice(id: "com.apple.voice.compact.es-MX.Paulina", name: "Paulina", language: "es-MX", quality: 0),
            SpeechLanguage.Voice(id: "com.apple.eloquence.es-MX.Eddy", name: "Eddy", language: "es-MX", quality: 0),
            SpeechLanguage.Voice(id: "com.apple.voice.enhanced.en-US.Samantha", name: "Samantha", language: "en-US", quality: 1),
        ]
        // Only basic voices: nil, the system's voice for the language (what it read with before).
        #expect(SpeechLanguage.voice(for: "es", region: "MX", among: basic, chosen: nil) == nil)
        let natural = basic + [
            SpeechLanguage.Voice(id: "com.apple.voice.enhanced.es-ES.Jorge", name: "Jorge", language: "es-ES", quality: 1),
            SpeechLanguage.Voice(id: "com.apple.voice.enhanced.es-MX.Paulina", name: "Paulina", language: "es-MX", quality: 1),
        ]
        // As natural as each other: the user's own region.
        #expect(SpeechLanguage.voice(for: "es", region: "MX", among: natural, chosen: nil)?.id == "com.apple.voice.enhanced.es-MX.Paulina")
        let premium = natural + [SpeechLanguage.Voice(id: "com.apple.voice.premium.es-ES.Monica", name: "Mónica", language: "es-ES", quality: 2)]
        #expect(SpeechLanguage.voice(for: "es", region: "MX", among: premium, chosen: nil)?.id == "com.apple.voice.premium.es-ES.Monica")
        // A voice picked by hand is used, whichever it is; one for another language (or deleted since) isn't.
        #expect(SpeechLanguage.voice(for: "es", region: "MX", among: basic, chosen: "com.apple.eloquence.es-MX.Eddy")?.name == "Eddy")
        #expect(SpeechLanguage.voice(for: "es", region: "MX", among: basic, chosen: "com.apple.voice.enhanced.en-US.Samantha") == nil)
    }
}

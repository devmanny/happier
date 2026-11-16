import Foundation
import Testing
@testable import HappierKit

/// How dictated text is written: the user's choices in Settings › Dictation, not one person's habits.
struct DictationStyleTests {
    @Test func byDefaultTextIsWrittenAsDictated() {
        #expect(DictationStyle().apply("Hola, ¿cómo estás? ¡Qué bien!") == "Hola, ¿cómo estás? ¡Qué bien!")
    }

    @Test func openingMarksCanBeLeftOut() {
        let style = DictationStyle(openingMarks: false)
        #expect(style.apply("Hola, ¿cómo estás? ¡Qué bien!") == "Hola, cómo estás? Qué bien!")
        #expect(style.apply("¿Sí?") == "Sí?")
    }

    @Test func everythingCanBeLowercase() {
        let style = DictationStyle(lowercase: true)
        #expect(style.apply("Busca una Mac Studio. ¿Vienes?") == "busca una mac studio. ¿vienes?")
    }

    @Test func sentencesCanRunOnWithCommas() {
        let style = DictationStyle(periods: false)
        // Casual writing: a comma where a sentence would end, and no closing period.
        #expect(style.apply("Ya llegué. Te veo abajo. ¿Bajas?") == "Ya llegué, te veo abajo, ¿Bajas?")
        #expect(style.apply("Listo.") == "Listo")
        // Ellipses, numbers and acronyms stay.
        #expect(style.apply("Pues... cuesta 3.5 mil. PDF adjunto.") == "Pues... cuesta 3.5 mil, PDF adjunto")
    }

    @Test func parenthesesAlwaysOpen() {
        #expect(DictationStyle(openingMarks: false).apply("Mañana (temprano) ¿vienes?") == "Mañana (temprano) vienes?")
    }

    @Test func allTogether() {
        #expect(DictationStyle(openingMarks: false, lowercase: true, periods: false).apply("Ya llegué. ¿Bajas?") == "ya llegué, bajas?")
    }

    @Test func bothTogether() {
        #expect(DictationStyle(openingMarks: false, lowercase: true).apply("¿Ya llegaste a la Oficina?") == "ya llegaste a la oficina?")
    }

    @Test func itIsReadFromTheSettings() throws {
        let defaults = try #require(UserDefaults(suiteName: "DictationStyleTests"))
        defaults.removePersistentDomain(forName: "DictationStyleTests")
        #expect(DictationStyle(defaults: defaults) == DictationStyle())
        defaults.set(false, forKey: DictationStyle.openingMarksKey)
        defaults.set(true, forKey: DictationStyle.lowercaseKey)
        defaults.set(false, forKey: DictationStyle.periodsKey)
        #expect(DictationStyle(defaults: defaults) == DictationStyle(openingMarks: false, lowercase: true, periods: false))
    }
}

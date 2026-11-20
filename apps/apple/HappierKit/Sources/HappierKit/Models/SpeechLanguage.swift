import Foundation
import NaturalLanguage

/// The language one dictation take is in (`SpeechLanguage.dictation`).
public struct DictationLanguage: Equatable, Sendable {
    /// The language code Whisper is told (`es`), or nil: Whisper recognizes the language spoken.
    public let whisper: String?
    /// The recognizer locale for Apple's engines (`es-MX`), which can't recognize the language
    /// spoken: on Automatic, the language Whisper heard last, else the device's first.
    public let apple: String?

    public init(whisper: String?, apple: String?) {
        self.whisper = whisper
        self.apple = apple
    }
}

/// The language and voice for dictation and reading aloud. The app's own text is English only, so
/// the system reports English as the app's language even on a Spanish phone: these go by the
/// user's languages (`Locale.preferredLanguages`) and region instead.
public enum SpeechLanguage {
    /// Ordered reading languages: the first one is used when the text has no detectable language.
    public static func readingLanguages(preferred: [String], chosen: [String] = []) -> [String] {
        var seen = Set<String>()
        let selected = (chosen.isEmpty ? preferred : chosen)
            .map { languageCode($0).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return selected.isEmpty ? ["en"] : selected
    }

    /// The language used by both individual-message and continuous read aloud.
    public static func readingLanguage(for text: String, allowed: [String]) -> String {
        let languages = readingLanguages(preferred: allowed)
        let recognizer = NLLanguageRecognizer()
        // Short Spanish replies can look Portuguese to Apple's unconstrained recognizer.
        // The user's reading languages are a hard boundary, not just a statistical hint.
        recognizer.languageConstraints = languages.flatMap { language -> [NLLanguage] in
            language == "zh" ? [.simplifiedChinese, .traditionalChinese] : [NLLanguage(rawValue: language)]
        }
        recognizer.processString(text)
        guard let detected = recognizer.dominantLanguage.map({ languageCode($0.rawValue) }), languages.contains(detected) else {
            return languages[0]
        }
        return detected
    }

    /// The recognizer locale for the first of the user's languages that dictation supports: that
    /// exact locale, else the language in the user's region, else the language anywhere.
    public static func dictationLocale(preferred: [String], region: String?, supported: [String]) -> String? {
        let supported = supported.map(normalized).sorted()
        for preference in preferred.map(normalized) {
            if supported.contains(preference) { return preference }
            let language = languageCode(preference)
            if let region, supported.contains("\(language)-\(region)") { return "\(language)-\(region)" }
            if let any = supported.first(where: { languageCode($0) == language }) { return any }
        }
        return nil
    }

    /// The recognizer locale with a language chosen in Settings › Dictation (a language code such
    /// as `es`; nil is Automatic): the chosen language in the user's region's variant, else, when
    /// the recognizers don't support it, the automatic choice from the user's languages.
    public static func dictationLocale(chosen: String?, preferred: [String], region: String?, supported: [String]) -> String? {
        dictationLocale(preferred: (chosen.map { [$0] } ?? []) + preferred, region: region, supported: supported)
    }

    /// The language a take is dictated in, with the language chosen in Settings › Dictation
    /// (`chosen`, nil: Automatic) and the one Whisper last recognized in a take (`heard`). Automatic
    /// doesn't tell Whisper a language: told the device's (English), it translated short passes of
    /// Spanish speech into English. A choice the recognizers don't support is Automatic.
    public static func dictation(chosen: String?, heard: String?, preferred: [String], region: String?,
                                 supported: [String]) -> DictationLanguage {
        let apple = dictationLocale(chosen: chosen ?? heard, preferred: preferred, region: region, supported: supported)
        let whisper = chosen.flatMap { chosen in apple.map(languageCode) == languageCode(chosen) ? languageCode(chosen) : nil }
        return DictationLanguage(whisper: whisper, apple: apple)
    }

    /// The languages Settings › Dictation offers: each supported language once (`es`, not every region).
    public static func dictationLanguages(supported: [String]) -> [String] {
        var seen = Set<String>()
        return supported.map(languageCode).filter { !$0.isEmpty && seen.insert($0).inserted }.sorted()
    }

    /// An installed voice; `quality` is 0 (default), 1 (enhanced) or 2 (premium).
    public struct Voice: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let language: String
        public let quality: Int

        public init(id: String, name: String, language: String, quality: Int) {
            self.id = id
            self.name = name
            self.language = normalized(language)
            self.quality = quality
        }
    }

    /// The voice for text in `language`: the one chosen for it if still installed, else the most
    /// natural Enhanced or Premium one, in the user's region when two are as good. Nil leaves it to
    /// the system's voice for the language: the basic voices are no better, and the old Eloquence
    /// synthesizers (Eddy, Flo, Reed…) are far worse.
    public static func voice(for language: String, region: String?, among voices: [Voice], chosen: String?) -> Voice? {
        let candidates = voices.filter { languageCode($0.language) == language }
        if let chosen, let voice = candidates.first(where: { $0.id == chosen }) { return voice }
        let local = region.map { "\(language)-\($0)" }
        return candidates
            .filter { $0.quality > 0 && !$0.id.contains(".eloquence.") }
            .max { a, b in (a.quality, a.language == local ? 1 : 0) < (b.quality, b.language == local ? 1 : 0) }
    }

    public static func languageCode(_ identifier: String) -> String {
        String(normalized(identifier).split(separator: "-").first ?? "")
    }

    static func normalized(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-")
    }
}

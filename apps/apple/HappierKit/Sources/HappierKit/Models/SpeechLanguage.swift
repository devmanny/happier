import Foundation

/// The language and voice for dictation and reading aloud. The app's own text is English only, so
/// the system reports English as the app's language even on a Spanish phone: these go by the
/// user's languages (`Locale.preferredLanguages`) and region instead.
public enum SpeechLanguage {
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

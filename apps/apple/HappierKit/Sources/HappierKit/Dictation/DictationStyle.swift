import Foundation

/// How dictated text is written, as each user chooses in Settings › Dictation: Whisper writes
/// formal, textbook Spanish (¿opening marks?, capitals, a period after every sentence), which in a
/// chat reads as written by an AI. Applied to every take, in the composer and the keyboard alike.
public struct DictationStyle: Equatable, Sendable {
    public static let openingMarksKey = "happier.dictation.openingMarks"
    public static let lowercaseKey = "happier.dictation.lowercase"
    public static let periodsKey = "happier.dictation.periods"

    /// "¿" and "¡" before a question or exclamation (never parentheses or quotes: those always open).
    public var openingMarks: Bool
    /// Everything in lowercase, names included.
    public var lowercase: Bool
    /// A period between sentences; without it, a comma, and no closing period.
    public var periods: Bool

    public init(openingMarks: Bool = true, lowercase: Bool = false, periods: Bool = true) {
        self.openingMarks = openingMarks
        self.lowercase = lowercase
        self.periods = periods
    }

    /// The style saved in Settings; written as dictated until the user changes it.
    public init(defaults: UserDefaults) {
        self.init(openingMarks: defaults.object(forKey: Self.openingMarksKey) as? Bool ?? true,
                  lowercase: defaults.bool(forKey: Self.lowercaseKey),
                  periods: defaults.object(forKey: Self.periodsKey) as? Bool ?? true)
    }

    public func apply(_ text: String) -> String {
        var text = text
        if !openingMarks { text.removeAll { $0 == "¿" || $0 == "¡" } }
        if !periods { text = Self.withCommas(text) }
        if lowercase { text = text.lowercased() }
        return text
    }

    /// "Ya llegué. Te veo abajo." → "Ya llegué, te veo abajo": a sentence's period becomes a comma
    /// and the word after it goes on in lowercase; the closing period goes. An ellipsis, a decimal
    /// point and an acronym stay.
    static func withCommas(_ text: String) -> String {
        var result = ""
        var chars = Array(text)
        while chars.last == ".", chars.count >= 2, chars[chars.count - 2] != "." { chars.removeLast() }
        var index = 0
        while index < chars.count {
            let char = chars[index]
            let ellipsis = (index > 0 && chars[index - 1] == ".") || (index + 1 < chars.count && chars[index + 1] == ".")
            guard char == ".", !ellipsis, index + 1 < chars.count, chars[index + 1] == " " else {
                result.append(char)
                index += 1
                continue
            }
            result.append(", ")
            index += 2
            // The next word goes on the sentence: "Te" → "te", but "PDF" stays.
            var word = ""
            while index < chars.count, chars[index].isLetter {
                word.append(chars[index])
                index += 1
            }
            let acronym = word.count > 1 && word.allSatisfy(\.isUppercase)
            result += acronym || word.isEmpty ? word : word.prefix(1).lowercased() + word.dropFirst()
        }
        return result
    }
}

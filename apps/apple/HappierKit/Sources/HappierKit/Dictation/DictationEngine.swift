/// The speech-to-text engine dictation uses on this device. Whisper once its model is downloaded
/// and the device can run it; until then Apple's own: SpeechAnalyzer where it has the language,
/// else the older SFSpeechRecognizer.
public enum DictationEngine: Equatable, Codable, Sendable {
    case whisper(WhisperModel)
    case speechTranscriber
    case speechRecognizer

    /// - Parameters:
    ///   - inUse: the Whisper model chosen on this device, if one is downloaded.
    ///   - deviceSupports: the models WhisperKit's device table lists for this device.
    ///   - speechTranscriber: whether SpeechAnalyzer can transcribe the dictation language right
    ///     now; asked only when Whisper isn't used (it costs time at the start of a take).
    public static func choose(inUse: WhisperModel?, deviceSupports: [String],
                              speechTranscriber: () async -> Bool) async -> DictationEngine {
        if let inUse, inUse.runs(onDeviceSupporting: deviceSupports) { return .whisper(inUse) }
        return await apple(speechTranscriber: speechTranscriber)
    }
}

/// Why a take Whisper was to dictate went to Apple's engine.
public enum DictationFallback: String, Codable, Sendable {
    /// Whisper's model wasn't in memory by the take's first-words deadline (still loading, or
    /// let go mid-take).
    case whisperNotLoaded
    /// Whisper had no words in the composer by its deadline.
    case whisperTooSlow
    /// Whisper stopped with an error, or was let go mid-take (low memory).
    case whisperFailed
}

extension DictationEngine {
    /// Apple's engine for the dictation language: SpeechAnalyzer where it has it, else the older one.
    public static func apple(speechTranscriber: () async -> Bool) async -> DictationEngine {
        await speechTranscriber() ? .speechTranscriber : .speechRecognizer
    }
}

/// The Whisper models dictation offers (Argmax's Core ML builds, downloaded from Hugging Face),
/// most accurate first. Only multilingual ones (dictation is in the user's language, never `.en`)
/// that WhisperKit 1.1.1's device table lists for current iPhones (A16, A17 Pro, A18).
///
/// Measured on a Mac mini M4 Pro (Neural Engine), live through the app's recognizer, 4 Spanish
/// clips (synthetic voices, 111 words), 10 Nov 2026: word errors 0 % Large v3 Turbo, 4.5 % Small,
/// 10.8 % Base, 25.2 % Tiny; first words 1.8 s / 1.2–2.2 s / 1.1–1.3 s / 1.1–2.1 s; final text
/// after letting go 1.0–1.9 s / 0.3–0.5 s / 0.2–0.5 s / 0.1–0.5 s. An iPhone is slower.
public enum WhisperModel: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Large v3 Turbo, compressed: the most accurate that runs on an iPhone.
    case largeV3Turbo = "openai_whisper-large-v3-v20240930_626MB"
    case small = "openai_whisper-small"
    case base = "openai_whisper-base"
    case tiny = "openai_whisper-tiny"

    /// The one Settings › Dictation recommends for an iPhone: no mistakes measured, and its passes
    /// (~1 s on the Mac) fit the first words' deadline. Small is the lighter choice.
    public static let recommended = WhisperModel.largeV3Turbo

    public var id: String { rawValue }

    /// The name WhisperKit downloads it by.
    public var variant: String { String(rawValue.dropFirst("openai_whisper-".count)) }

    /// Bytes downloaded: the model's files on Hugging Face (argmaxinc/whisperkit-coreml, 10 Nov 2026).
    public var downloadBytes: Int64 {
        switch self {
        case .largeV3Turbo: 626_718_238
        case .small: 486_487_465
        case .base: 146_719_453
        case .tiny: 76_635_397
        }
    }

    /// Whether a device whose WhisperKit table lists `supported` can run this model.
    public func runs(onDeviceSupporting supported: [String]) -> Bool {
        supported.contains(rawValue)
    }
}

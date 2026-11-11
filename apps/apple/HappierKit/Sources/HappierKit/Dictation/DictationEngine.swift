/// The speech-to-text engine dictation uses on this device. Whisper once its model is downloaded
/// and the device can run it; until then Apple's own: SpeechAnalyzer where it has the language,
/// else the older SFSpeechRecognizer.
public enum DictationEngine: Equatable, Codable, Sendable {
    case whisper(WhisperModel)
    case speechTranscriber
    case speechRecognizer

    /// - Parameters:
    ///   - installed: the Whisper model on this device, if one is downloaded.
    ///   - deviceSupports: the models WhisperKit's device table lists for this device.
    ///   - speechTranscriber: whether SpeechAnalyzer can transcribe the dictation language right
    ///     now; asked only when Whisper isn't used (it costs time at the start of a take).
    public static func choose(installed: WhisperModel?, deviceSupports: [String],
                              speechTranscriber: () async -> Bool) async -> DictationEngine {
        if let installed, installed.runs(onDeviceSupporting: deviceSupports) { return .whisper(installed) }
        return await apple(speechTranscriber: speechTranscriber)
    }
}

/// Why a take Whisper was to dictate went to Apple's engine.
public enum DictationFallback: String, Codable, Sendable {
    /// Whisper wasn't loaded when the take began (it loads meanwhile, for the next one).
    case whisperNotLoaded
    /// Whisper had no words in the composer by its deadline.
    case whisperTooSlow
    /// Whisper stopped with an error, or was let go mid-take (low memory).
    case whisperFailed
}

/// The engine one take starts with, and why it isn't the device's Whisper when it isn't.
public struct DictationTake: Equatable, Sendable {
    public let engine: DictationEngine
    public let fallback: DictationFallback?

    public init(engine: DictationEngine, fallback: DictationFallback?) {
        self.engine = engine
        self.fallback = fallback
    }
}

extension DictationEngine {
    /// Apple's engine for the dictation language: SpeechAnalyzer where it has it, else the older one.
    public static func apple(speechTranscriber: () async -> Bool) async -> DictationEngine {
        await speechTranscriber() ? .speechTranscriber : .speechRecognizer
    }

    /// The engine a take starts with. A take never waits for Whisper to load (seconds, minutes when
    /// the system recompiles it): Apple's engine dictates it meanwhile. Only without speech
    /// recognition allowed (Whisper asks for the microphone alone) does it wait for Whisper.
    public static func forTake(_ configured: DictationEngine, whisperLoaded: Bool, appleAllowed: Bool,
                               speechTranscriber: () async -> Bool) async -> DictationTake {
        guard case .whisper = configured, !whisperLoaded, appleAllowed else { return DictationTake(engine: configured, fallback: nil) }
        return DictationTake(engine: await apple(speechTranscriber: speechTranscriber), fallback: .whisperNotLoaded)
    }
}

/// The Whisper model dictation offers (Argmax's Core ML build, downloaded from Hugging Face).
/// Small was measured and left out: less accurate in Spanish than Apple's SpeechTranscriber,
/// which needs no download (10 Nov 2026).
public enum WhisperModel: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Large v3 Turbo, compressed: the most accurate that runs on an iPhone.
    case largeV3Turbo = "openai_whisper-large-v3-v20240930_626MB"

    public var id: String { rawValue }

    /// The name WhisperKit downloads it by.
    public var variant: String { String(rawValue.dropFirst("openai_whisper-".count)) }

    /// Bytes downloaded, as measured on 10 Nov 2026 (the files on Hugging Face).
    public var downloadBytes: Int64 {
        switch self {
        case .largeV3Turbo: 626_718_238
        }
    }

    /// Whether a device whose WhisperKit table lists `supported` can run this model.
    public func runs(onDeviceSupporting supported: [String]) -> Bool {
        supported.contains(rawValue)
    }
}

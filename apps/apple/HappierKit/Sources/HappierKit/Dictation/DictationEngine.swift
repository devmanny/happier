/// The speech-to-text engine dictation uses on this device. Whisper once its model is downloaded
/// and the device can run it; until then Apple's own: SpeechAnalyzer where it has the language,
/// else the older SFSpeechRecognizer.
public enum DictationEngine: Equatable, Sendable {
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
        return await speechTranscriber() ? .speechTranscriber : .speechRecognizer
    }
}

/// The Whisper model dictation offers (Argmax's Core ML build, downloaded from Hugging Face).
/// Small was measured and left out: less accurate in Spanish than Apple's SpeechTranscriber,
/// which needs no download (10 Nov 2026).
public enum WhisperModel: String, CaseIterable, Identifiable, Sendable {
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

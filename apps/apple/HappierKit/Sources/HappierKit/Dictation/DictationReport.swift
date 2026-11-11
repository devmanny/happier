import Foundation

/// What the last dictation on this device did, for Settings › Dictation: which engine wrote the
/// words and why, and how long they took. A slow or empty take can then be told apart without logs.
public struct DictationReport: Codable, Equatable, Sendable {
    /// When the microphone started listening.
    public var date: Date
    /// The engine whose words went into the composer.
    public var engine: DictationEngine
    /// Why it wasn't Whisper, when Whisper is the device's engine.
    public var fallback: DictationFallback?
    /// Seconds from listening to the first words in the composer; nil when none came.
    public var firstText: TimeInterval?
    public var whisperPasses = 0
    public var slowestPass: TimeInterval?
    /// The take's loudest 100 ms and its background (dBFS), as Whisper's speech detection heard
    /// them: a take with no passes had no speech above its background (`DictationSpeech`).
    public var loudestLevel: Float?
    public var backgroundLevel: Float?
    /// `ProcessInfo.ThermalState`'s raw value when the take began.
    public var thermalState = 0
    public var lowPowerMode = false

    public init(date: Date, engine: DictationEngine, fallback: DictationFallback?) {
        self.date = date
        self.engine = engine
        self.fallback = fallback
    }

    /// The composer now shows `text` from this take (an empty update is no words yet).
    public mutating func shown(_ text: String, at time: Date) {
        guard firstText == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        firstText = time.timeIntervalSince(date)
    }

    /// One Whisper pass took `seconds`.
    public mutating func pass(seconds: TimeInterval) {
        whisperPasses += 1
        slowestPass = max(slowestPass ?? 0, seconds)
    }

    /// The take's loudness so far, in `DictationSpeech.frameSeconds` frames (dBFS).
    public mutating func heard(frameLevels levels: [Float]) {
        loudestLevel = levels.max()
        backgroundLevel = DictationSpeech.background(frameLevels: levels)
    }

    /// Apple's `engine` took the take over from Whisper.
    public mutating func handedOver(to engine: DictationEngine, because reason: DictationFallback) {
        self.engine = engine
        fallback = reason
    }
}

/// The Whisper model's state in memory, for Settings › Dictation.
public struct WhisperModelStatus: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case notLoaded, loading, loaded, failed
    }

    /// Why a loaded model was let go.
    public enum Unload: String, Codable, Sendable {
        /// The app left the screen (iPhone, iPad); it loads again when the app is back.
        case background
        /// The system ran low on memory; it loads again at the next dictation.
        case lowMemory
        case deleted
    }

    public var phase: Phase = .notLoaded
    public var since: Date?
    /// The last load that finished, in seconds (minutes when the system had to compile it again).
    public var lastLoadSeconds: TimeInterval?
    public var unloaded: Unload?
    public var failure: String?

    public init() {}
}

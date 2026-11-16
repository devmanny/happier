import Foundation

/// What the app is using audio for. iOS gives an app one audio session; Oído, dictation and
/// reading aloud each say what they need and `AudioSessionUses` decides the one configuration.
public enum AudioUse: Sendable, Hashable {
    /// Oído, all day: other apps' audio keeps playing at its volume.
    case listening
    /// Dictating into a composer: other audio is lowered while it listens (when Oído isn't on).
    case dictating
    /// Reading a message aloud: plays with the silent switch on; lowers other audio when asked.
    case reading(ducksOthers: Bool)

    public var records: Bool { self == .listening || self == .dictating }

    /// Oído waits for a microphone that a call or another app holds and comes back by itself;
    /// a dictation take that can't open the microphone fails at once and says so.
    public var waitsForMicrophone: Bool { self == .listening }
}

/// The audio session's configuration, in the platform's terms (`AVAudioSession` category, mode
/// and options), kept free of AVFoundation so it can be decided and tested here.
public struct AudioSessionPlan: Sendable, Equatable {
    public enum Category: Sendable, Equatable { case playAndRecord, playback }
    public enum Mode: Sendable, Equatable { case standard, spokenAudio }
    public struct Options: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let mixWithOthers = Options(rawValue: 1 << 0)
        public static let duckOthers = Options(rawValue: 1 << 1)
        public static let defaultToSpeaker = Options(rawValue: 1 << 2)
        public static let allowBluetoothA2DP = Options(rawValue: 1 << 3)
    }

    public var category: Category
    public var mode: Mode
    public var options: Options

    public init(category: Category, mode: Mode, options: Options) {
        self.category = category
        self.mode = mode
        self.options = options
    }

    /// The configuration for everything in use at once; nil when nothing is.
    ///
    /// Recording wins: reading aloud plays fine through a play-and-record session, while switching
    /// to playback would take the microphone from Oído. Oído's mixing wins over dictation's ducking:
    /// iOS lowers other audio only from the session's activation, so ducking for a take would mean
    /// deactivating the session under Oído's recording (and, in the background, not getting it back).
    public static func resolve(_ uses: some Sequence<AudioUse>) -> AudioSessionPlan? {
        var listening = false, dictating = false, reading = false, readingDucks = false
        for use in uses {
            switch use {
            case .listening: listening = true
            case .dictating: dictating = true
            case .reading(let ducks):
                reading = true
                readingDucks = readingDucks || ducks
            }
        }
        // Bluetooth headphones play in A2DP; the microphone stays the device's own (HFP would
        // drop music to call quality all day).
        if listening {
            return AudioSessionPlan(category: .playAndRecord, mode: .standard, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        }
        if dictating {
            return AudioSessionPlan(category: .playAndRecord, mode: .standard, options: [.duckOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        }
        if reading {
            return AudioSessionPlan(category: .playback, mode: .spokenAudio, options: readingDucks ? [.duckOthers] : [.mixWithOthers])
        }
        return nil
    }
}

/// Who holds the audio session and for what. One holder leaving never deactivates the session
/// while another still uses it (dictation ending must not cut off Oído); the last one leaving does.
public struct AudioSessionUses<Holder: Hashable & Sendable>: Sendable {
    public enum Change: Sendable, Equatable {
        /// Configure the session this way and make sure it's active.
        case activate(AudioSessionPlan)
        /// Nobody uses audio any more: deactivate, letting other apps' audio back up.
        case deactivate
        /// Nothing to do.
        case keep
    }

    private var uses: [Holder: AudioUse] = [:]
    public private(set) var plan: AudioSessionPlan?

    public init() {}

    public var isEmpty: Bool { uses.isEmpty }

    /// `holder` starts using audio for `use` (or switches to it). Always asks for activation: the
    /// session may have been deactivated by the system since (a call), and activating twice is harmless.
    public mutating func begin(_ use: AudioUse, by holder: Holder) -> Change {
        uses[holder] = use
        plan = AudioSessionPlan.resolve(uses.values)
        return plan.map(Change.activate) ?? .keep
    }

    public mutating func end(by holder: Holder) -> Change {
        guard uses.removeValue(forKey: holder) != nil else { return .keep }
        let previous = plan
        plan = AudioSessionPlan.resolve(uses.values)
        guard let plan else { return previous == nil ? .keep : .deactivate }
        return plan == previous ? .keep : .activate(plan)
    }
}

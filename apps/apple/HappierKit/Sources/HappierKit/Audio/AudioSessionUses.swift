import Foundation

/// What the app is using audio for. iOS gives an app one audio session; Oído, dictation and
/// reading aloud each say what they need and `AudioSessionUses` decides the one configuration.
public enum AudioUse: Sendable, Hashable {
    /// Oído, all day: other apps' audio keeps playing at its volume.
    case listening
    /// Dictating into a composer: other audio is lowered while it listens (when nothing else that
    /// mixes holds the session).
    case dictating
    /// Reading a message aloud: plays with the silent switch on; lowers other audio when asked.
    case reading(ducksOthers: Bool)
    /// The dictation keyboard's microphone, kept on in the background between takes (an app can't
    /// start recording from the background, so the keyboard's takes ride on this). Mixes like Oído.
    case standby

    public var records: Bool { self == .listening || self == .dictating || self == .standby }

    /// Whether this use alone would lower other apps' audio (`AudioSessionPlan.resolve` decides
    /// for all of them together).
    public var ducksOthers: Bool {
        switch self {
        case .dictating: true
        case .reading(let ducks): ducks
        case .listening, .standby: false
        }
    }

    /// Oído waits for a microphone that a call or another app holds and comes back by itself;
    /// a dictation take that can't open the microphone fails at once and says so.
    public var waitsForMicrophone: Bool { self == .listening }
}

/// The audio session's configuration, kept free of AVFoundation so it can be decided and tested
/// here. Always the play-and-record category in its default mode, without the AirPlay option, for
/// every use: playback would follow AirPlay to a TV by itself (Apple implies AirPlay for the
/// output-only categories), while play-and-record reaches non-mirrored AirPlay only with
/// `.allowAirPlay`, which Happier never sets. One category for everything also means a dictation
/// take starting under a reply being read doesn't move the route under the microphone.
public struct AudioSessionPlan: Sendable, Equatable {
    public struct Options: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let mixWithOthers = Options(rawValue: 1 << 0)
        public static let duckOthers = Options(rawValue: 1 << 1)
        public static let defaultToSpeaker = Options(rawValue: 1 << 2)
        public static let allowBluetoothA2DP = Options(rawValue: 1 << 3)
    }

    public var options: Options
    /// Happier is speaking or dictating. Play-and-record still follows a mirrored screen to the TV
    /// (Apple's category documentation), so while this is set and the output is AirPlay, the
    /// sound and the microphone are moved back to the iPhone. Oído or the keyboard's standby
    /// alone leave the route as the user chose it.
    public var staysOffAirPlay: Bool

    public init(options: Options, staysOffAirPlay: Bool) {
        self.options = options
        self.staysOffAirPlay = staysOffAirPlay
    }

    /// The configuration for everything in use at once; nil when nothing is.
    ///
    /// Other audio is lowered only while every use wants it. iOS lowers it when the session
    /// activates and raises it again only when the session ends, so a use that mixes and stays
    /// (Oído all day, auto read waiting for the next message) must never inherit a lowering it
    /// can't undo: ending it would mean deactivating the session under Oído's recording (and, in
    /// the background, not getting it back).
    public static func resolve(_ uses: some Sequence<AudioUse>) -> AudioSessionPlan? {
        var any = false, ducks = true, ownSound = false
        for use in uses {
            any = true
            ducks = ducks && use.ducksOthers
            switch use {
            case .dictating, .reading: ownSound = true
            case .listening, .standby: break
            }
        }
        guard any else { return nil }
        // Bluetooth headphones play in A2DP; the microphone stays the device's own (HFP would
        // drop music to call quality all day).
        return AudioSessionPlan(options: [ducks ? .duckOthers : .mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP],
                                staysOffAirPlay: ownSound)
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

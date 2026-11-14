import Foundation

/// Apple Pencil Pro squeezes on the composer: two in quick succession start dictation (the
/// composer's blue mic, not push to talk), so a stray squeeze doesn't open the mic; one squeeze
/// while it listens stops it and keeps the text in the field, unsent.
public struct PencilSqueezeDictation: Sendable {
    public enum Action: Sendable, Equatable {
        case start
        /// Stop listening and keep the text (`Dictation.finish`).
        case finish
        case none
    }

    /// The most time between the two squeezes that start dictation (about a double-click's).
    public static let doubleSqueezeWindow: TimeInterval = 0.6

    /// The last squeeze while idle that hasn't been paired yet.
    private var pendingSqueeze: Date?

    public init() {}

    public mutating func squeezed(at now: Date, recording: Bool) -> Action {
        guard !recording else {
            pendingSqueeze = nil
            return .finish
        }
        if let pending = pendingSqueeze, now.timeIntervalSince(pending) <= Self.doubleSqueezeWindow {
            pendingSqueeze = nil
            return .start
        }
        pendingSqueeze = now
        return .none
    }
}

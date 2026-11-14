import Foundation

/// Apple Pencil Pro squeezes on the composer: one squeeze starts dictation (the composer's blue
/// mic, not push to talk); two in quick succession while it listens stop it and keep the text in
/// the field, unsent. A lone squeeze while listening does nothing, so a stray one doesn't cut the
/// dictation short.
public struct PencilSqueezeDictation: Sendable {
    public enum Action: Sendable, Equatable {
        case start
        /// Stop listening and keep the text (`Dictation.finish`).
        case finish
        case none
    }

    /// The most time between the two squeezes that stop dictation (about a double-click's).
    public static let doubleSqueezeWindow: TimeInterval = 0.6

    /// The last squeeze while listening that hasn't been paired yet.
    private var pendingSqueeze: Date?

    public init() {}

    public mutating func squeezed(at now: Date, recording: Bool) -> Action {
        guard recording else {
            pendingSqueeze = nil
            return .start
        }
        if let pending = pendingSqueeze, now.timeIntervalSince(pending) <= Self.doubleSqueezeWindow {
            pendingSqueeze = nil
            return .finish
        }
        pendingSqueeze = now
        return .none
    }
}

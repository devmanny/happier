/// The effort mark of the model pill: one bar per effort level the model's catalog offers (the
/// same list the Effort picker shows, so Claude has 5 and Codex 6), filled up to the current level.
/// Ultracode runs above every level, so it shows all of them filled.
public struct EffortBars: Equatable, Sendable {
    public let count: Int
    public let filled: Int

    public init(count: Int, filled: Int) {
        self.count = count
        self.filled = filled
    }

    /// Nil when the model has no effort levels. A level its catalog doesn't list fills none.
    public init?(level: String, levels: [String], ultracode: Bool = false) {
        guard !levels.isEmpty else { return nil }
        count = levels.count
        filled = ultracode ? levels.count : (levels.firstIndex(of: level).map { $0 + 1 } ?? 0)
    }
}

import Foundation

/// The loading indicator of the official app (`ActivitySpinner`, default style `wave` on the
/// Happier mark, Normal speed, Short pause — `dotSpinnerStyles.ts`): an H of dots on a 3 × 3 grid
/// with a foot dot at the bottom centre, and light travelling diagonally from the bottom-left foot to
/// the top-right corner, then a short rest.
public enum HappierMark {
    public struct Dot: Equatable, Sendable {
        public let id: String
        public let col: Int
        public let row: Int
    }

    public static let dots: [Dot] = [
        Dot(id: "TL", col: 0, row: 0), Dot(id: "ML", col: 0, row: 1), Dot(id: "BL", col: 0, row: 2),
        Dot(id: "MC", col: 1, row: 1),
        Dot(id: "TR", col: 2, row: 0), Dot(id: "MR", col: 2, row: 1), Dot(id: "BR", col: 2, row: 2),
        Dot(id: "BC", col: 1, row: 2),
    ]

    /// Ink on an idle dot.
    public static let restOpacity = 0.2
    /// Every dot when motion is reduced or paused: the still mark.
    public static let stillOpacity = 0.85

    /// Fast attack, short plateau, soft tail (ms since the dot lit → opacity).
    private static let pulse: [(at: Double, opacity: Double)] = [(0, restOpacity), (65, 1), (234, 0.88), (364, restOpacity)]
    private static let stepMs = 110.0
    private static let pauseMs = 200.0
    private static let motionMs = 4 * stepMs + 364

    /// One loop: the light crossing the mark, then the rest.
    public static let cycleMs = motionMs + pauseMs

    /// 0 at the bottom-left foot, 4 at the top-right corner.
    private static func rank(_ dot: Dot) -> Double { Double(dot.col + (2 - dot.row)) }

    public static func opacity(_ dot: Dot, atMs time: Double) -> Double {
        let t = time.truncatingRemainder(dividingBy: cycleMs) - rank(dot) * stepMs
        guard t > pulse[0].at else { return pulse[0].opacity }
        for index in 1..<pulse.count where t <= pulse[index].at {
            let (a, va) = pulse[index - 1]
            let (b, vb) = pulse[index]
            return va + (vb - va) * (t - a) / (b - a)
        }
        return restOpacity
    }
}

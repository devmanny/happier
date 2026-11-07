import CoreGraphics

/// Where the composer's status pill goes when it's dropped after a drag: the side its projected
/// resting point falls on. The projection is the distance a scroll view would coast at that
/// velocity (normal deceleration), as Picture in Picture does, so a hard flick carries it to the
/// side it was thrown toward and a slow release picks the nearest side.
public enum StatusSideSnap {
    /// `UIScrollView.DecelerationRate.normal`.
    public static let decelerationRate: CGFloat = 0.998

    /// How far a release at `velocity` (points per second) would coast.
    public static func projectedDistance(velocity: CGFloat) -> CGFloat {
        (velocity / 1000) * decelerationRate / (1 - decelerationRate)
    }

    /// The side for a pill whose center is at `center` in a row `width` wide.
    public static func side(center: CGFloat, velocity: CGFloat, width: CGFloat) -> AccountSettings.StatusPosition {
        center + projectedDistance(velocity: velocity) < width / 2 ? .left : .right
    }
}

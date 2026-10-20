import Foundation

/// Keeps the chat on its newest message (iMessage behaviour). The chat is pinned to the end when it
/// opens and when you send; while pinned, anything that moves the end (rows measured at their real
/// height, typing dots, a streamed reply, a taller composer) scrolls back to it. Dragging up unpins;
/// dragging back to the end pins again.
public enum ChatScroll {
    /// SwiftUI `ScrollGeometry` as measured on device: `containerHeight` is the unobscured height
    /// between the insets, and `offsetY` is the top of the area under the top inset.
    public struct Geometry: Equatable, Sendable {
        public var offsetY: Double
        public var containerHeight: Double
        public var contentHeight: Double
        public var topInset: Double

        public init(offsetY: Double, containerHeight: Double, contentHeight: Double, topInset: Double) {
            self.offsetY = offsetY
            self.containerHeight = containerHeight
            self.contentHeight = contentHeight
            self.topInset = topInset
        }

        /// The offset that shows the last message right above the composer. A chat shorter than the
        /// screen rests at the top of its scroll range (`-topInset`), with everything visible.
        public var endOffset: Double { max(contentHeight - containerHeight - topInset, -topInset) }

        /// How far the viewport sits past (positive) or short of (negative) the last message.
        var distanceFromEnd: Double { offsetY - endOffset }

        /// Everything fits on screen; the bottom-anchored scroll view already rests on the end.
        public var fitsOnScreen: Bool { contentHeight <= containerHeight }

        /// Within a short line of the last message.
        public var isAtEnd: Bool { distanceFromEnd >= -44 }
    }

    /// A pinned chat sits exactly on the end: short of it (taller rows, a taller composer) or past
    /// it (a row collapsed and left a gap) both scroll back.
    public static func shouldFollow(pinned: Bool, geometry: Geometry) -> Bool {
        // Past the top of the scroll range the view is bouncing back on its own.
        let settling = geometry.offsetY < -geometry.topInset - 1
        return pinned && !settling && abs(geometry.distanceFromEnd) > 1
    }

    public static func isPinned(afterUserScrollTo geometry: Geometry) -> Bool {
        geometry.isAtEnd
    }
}

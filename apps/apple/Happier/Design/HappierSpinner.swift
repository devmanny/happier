import HappierKit
import SwiftUI

/// Every loading indicator in the app: the official app's `ActivitySpinner` (the Happier mark with
/// light travelling through it, `HappierMark`). With Reduce Motion it holds the still mark.
struct HappierSpinner: View {
    /// Tool lines and other compact status slots.
    static let mini: CGFloat = 14
    /// Inline in rows, toolbars and buttons.
    static let small: CGFloat = 20
    /// Alone on an otherwise empty screen or pane.
    static let hero: CGFloat = 54

    var size: CGFloat = HappierSpinner.small
    /// Defaults to the secondary text color, like the official app.
    var color: Color?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 30 fps, the official app's frame rate for this mark; the timeline stops when off screen.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let ms = context.date.timeIntervalSinceReferenceDate * 1000
            Canvas { canvas, _ in
                let pitch = size / 3
                let diameter = size / 6
                for dot in HappierMark.dots {
                    var layer = canvas
                    layer.opacity = reduceMotion ? HappierMark.stillOpacity : HappierMark.opacity(dot, atMs: ms)
                    let rect = CGRect(x: (CGFloat(dot.col) + 0.5) * pitch - diameter / 2,
                                      y: (CGFloat(dot.row) + 0.5) * pitch - diameter / 2,
                                      width: diameter, height: diameter)
                    layer.fill(Path(ellipseIn: rect), with: .foreground)
                }
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
        .accessibilityElement()
        .accessibilityLabel(Text("Loading"))
        .accessibilityAddTraits(.updatesFrequently)
    }
}

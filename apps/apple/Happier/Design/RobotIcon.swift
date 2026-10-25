import SwiftUI

/// A robot head for agents running in the background (SF Symbols has none). Drawn on a 24-point
/// grid after Lucide's `bot` icon (ISC license) and stroked like a symbol, so it takes the
/// surrounding foreground style.
struct RobotIcon: View {
    var size: CGFloat = 14

    var body: some View {
        RobotShape()
            .stroke(style: StrokeStyle(lineWidth: size / 12, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct RobotShape: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit) }
        var path = Path()
        // Antenna.
        path.move(to: point(12, 8)); path.addLine(to: point(12, 4)); path.addLine(to: point(8, 4))
        // Head.
        path.addRoundedRect(in: CGRect(origin: point(4, 8), size: CGSize(width: 16 * unit, height: 12 * unit)),
                            cornerSize: CGSize(width: 2 * unit, height: 2 * unit))
        // Ears.
        path.move(to: point(2, 14)); path.addLine(to: point(4, 14))
        path.move(to: point(20, 14)); path.addLine(to: point(22, 14))
        // Eyes.
        path.move(to: point(9, 13)); path.addLine(to: point(9, 15))
        path.move(to: point(15, 13)); path.addLine(to: point(15, 15))
        return path
    }
}

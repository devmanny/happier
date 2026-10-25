import SwiftUI

extension View {
    /// A band of light sweeping across, like a loading skeleton, while `active`: how a running step
    /// shows it is going without a spinner. Still (dimmed) under Reduce Motion.
    func shimmer(_ active: Bool) -> some View {
        modifier(Shimmer(active: active))
    }
}

private struct Shimmer: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let period: TimeInterval = 1.8
    private static let dim = 0.4

    func body(content: Content) -> some View {
        if !active {
            content
        } else if reduceMotion {
            content.opacity(0.7)
        } else {
            // Redraws only while on screen: an off-screen row's timeline stops.
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let progress = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
                content.mask {
                    GeometryReader { proxy in
                        let band = max(proxy.size.width * 0.5, 60)
                        ZStack(alignment: .leading) {
                            Color.black.opacity(Self.dim)
                            LinearGradient(colors: [.black.opacity(Self.dim), .black, .black.opacity(Self.dim)],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: band)
                                .offset(x: -band + (proxy.size.width + band) * progress)
                        }
                    }
                }
            }
        }
    }
}

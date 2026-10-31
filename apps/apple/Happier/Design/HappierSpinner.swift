import HappierKit
import QuartzCore
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
        // Core Animation plays the light by itself. A SwiftUI timeline here redrew the whole window
        // 30 times a second for every working session on screen, which kept the CPU busy and the
        // phone warm.
        HappierMarkView(size: size, color: color ?? .secondary, animated: !reduceMotion)
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(Text("Loading"))
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The mark's dots as layers, each with its light as a looping keyframe animation.
@MainActor
private final class HappierMarkLayers {
    let root = CALayer()
    private let dots: [CALayer] = HappierMark.dots.map { _ in CALayer() }
    private var animated = false
    private static let key = "happier.mark"

    init() {
        #if os(macOS)
        root.isGeometryFlipped = true
        #endif
        dots.forEach(root.addSublayer)
    }

    func configure(size: CGFloat, color: CGColor, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = CGRect(x: 0, y: 0, width: size, height: size)
        let pitch = size / 3
        let diameter = size / 6
        for (dot, layer) in zip(HappierMark.dots, dots) {
            layer.frame = CGRect(x: (CGFloat(dot.col) + 0.5) * pitch - diameter / 2,
                                 y: (CGFloat(dot.row) + 0.5) * pitch - diameter / 2,
                                 width: diameter, height: diameter)
            layer.cornerRadius = diameter / 2
            layer.backgroundColor = color
        }
        CATransaction.commit()
        if animated != self.animated || (animated && dots.first?.animation(forKey: Self.key) == nil) {
            self.animated = animated
            restart()
        }
    }

    /// Back in a window: the animations may have been dropped while out of it.
    func resume() {
        guard animated, dots.first?.animation(forKey: Self.key) == nil else { return }
        restart()
    }

    private func restart() {
        let duration = HappierMark.cycleMs / 1000
        // In step with every other spinner on screen, as when they all read the same clock.
        let phase = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: duration)
        for (dot, layer) in zip(HappierMark.dots, dots) {
            layer.removeAnimation(forKey: Self.key)
            guard animated else {
                layer.opacity = Float(HappierMark.stillOpacity)
                continue
            }
            layer.opacity = Float(HappierMark.restOpacity)
            let frames = HappierMark.keyframes(for: dot)
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = frames.map(\.opacity)
            animation.keyTimes = frames.map { NSNumber(value: $0.time) }
            animation.duration = duration
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - phase
            layer.add(animation, forKey: Self.key)
        }
    }
}

#if os(iOS)
private struct HappierMarkView: UIViewRepresentable {
    let size: CGFloat
    let color: Color
    let animated: Bool

    func makeUIView(context: Context) -> MarkView { MarkView() }

    func updateUIView(_ view: MarkView, context: Context) {
        view.marks.configure(size: size, color: color.resolve(in: context.environment).cgColor, animated: animated)
    }

    final class MarkView: UIView {
        let marks = HappierMarkLayers()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            layer.addSublayer(marks.root)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { marks.resume() }
        }
    }
}
#else
private struct HappierMarkView: NSViewRepresentable {
    let size: CGFloat
    let color: Color
    let animated: Bool

    func makeNSView(context: Context) -> MarkView { MarkView() }

    func updateNSView(_ view: MarkView, context: Context) {
        view.marks.configure(size: size, color: color.resolve(in: context.environment).cgColor, animated: animated)
    }

    final class MarkView: NSView {
        let marks = HappierMarkLayers()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(marks.root)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { marks.resume() }
        }
    }
}
#endif

/// The typing indicator's three dots, fading one after another, as layers.
struct PulsingDots: View {
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PulsingDotsView(color: color, animated: !reduceMotion)
    }
}

@MainActor
private final class PulsingDotsLayers {
    let root = CALayer()
    private let dots: [CALayer] = (0..<3).map { _ in CALayer() }
    private var animated = false
    private static let key = "happier.dots"
    static let diameter: CGFloat = 8
    static let spacing: CGFloat = 5

    init() { dots.forEach(root.addSublayer) }

    func configure(color: CGColor, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = CGRect(x: 0, y: 0, width: 3 * Self.diameter + 2 * Self.spacing, height: Self.diameter)
        for (index, dot) in dots.enumerated() {
            dot.frame = CGRect(x: CGFloat(index) * (Self.diameter + Self.spacing), y: 0, width: Self.diameter, height: Self.diameter)
            dot.cornerRadius = Self.diameter / 2
            dot.backgroundColor = color
        }
        CATransaction.commit()
        if animated != self.animated || (animated && dots.first?.animation(forKey: Self.key) == nil) {
            self.animated = animated
            restart()
        }
    }

    func resume() {
        guard animated, dots.first?.animation(forKey: Self.key) == nil else { return }
        restart()
    }

    private func restart() {
        for (index, dot) in dots.enumerated() {
            dot.removeAnimation(forKey: Self.key)
            dot.opacity = animated ? 0.35 : 0.6
            guard animated else { continue }
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 0.35
            animation.toValue = 1
            animation.duration = 0.5
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation.isRemovedOnCompletion = false
            animation.beginTime = dot.convertTime(CACurrentMediaTime(), from: nil) + Double(index) * 0.18
            animation.fillMode = .backwards
            dot.add(animation, forKey: Self.key)
        }
    }
}

#if os(iOS)
private struct PulsingDotsView: UIViewRepresentable {
    let color: Color
    let animated: Bool

    func makeUIView(context: Context) -> DotsView { DotsView() }

    func updateUIView(_ view: DotsView, context: Context) {
        view.dots.configure(color: color.resolve(in: context.environment).cgColor, animated: animated)
    }

    final class DotsView: UIView {
        let dots = PulsingDotsLayers()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            layer.addSublayer(dots.root)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { dots.resume() }
        }
    }
}
#else
private struct PulsingDotsView: NSViewRepresentable {
    let color: Color
    let animated: Bool

    func makeNSView(context: Context) -> DotsView { DotsView() }

    func updateNSView(_ view: DotsView, context: Context) {
        view.dots.configure(color: color.resolve(in: context.environment).cgColor, animated: animated)
    }

    final class DotsView: NSView {
        let dots = PulsingDotsLayers()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(dots.root)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { dots.resume() }
        }
    }
}
#endif

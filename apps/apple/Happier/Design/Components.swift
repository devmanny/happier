import HappierKit
import SwiftUI

/// The agent's logo on a neutral disc: near black in dark mode, near white in light mode.
struct SessionAvatar: View {
    let session: Session
    var size: CGFloat = 52

    var body: some View {
        ZStack {
            Circle().fill(Color.avatarBackground)
            if let agent = session.agentId {
                Image("Agents/\(agent)")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.primary)
                    .frame(width: size * 0.5, height: size * 0.5)
            } else {
                Image(systemName: "sparkle")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

/// iMessage bubble: generous continuous corners and, on the last bubble of a run, the curved tail
/// that sweeps out of the bottom corner. Every bubble reserves `tailWidth` on its tail side so a
/// run's bubbles stay aligned whether or not they carry the tail.
struct BubbleShape: Shape {
    static let tailWidth: CGFloat = 8

    var fromUser: Bool
    var tail: Bool

    func path(in rect: CGRect) -> Path {
        var path = Self.sentBubble(width: rect.width, height: rect.height, tail: tail)
        if !fromUser {
            path = path.applying(CGAffineTransform(translationX: rect.width, y: 0).scaledBy(x: -1, y: 1))
        }
        return path.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    /// Bubble with its tail on the right, in a `width`×`height` box (tail flush with the right edge).
    private static func sentBubble(width w: CGFloat, height h: CGFloat, tail: Bool) -> Path {
        let r = min(18, h / 2)
        let k: CGFloat = 0.47  // control-point factor for continuous-looking corners
        let right = w - tailWidth
        var p = Path()
        p.move(to: CGPoint(x: r, y: 0))
        p.addLine(to: CGPoint(x: right - r, y: 0))
        p.addCurve(to: CGPoint(x: right, y: r), control1: CGPoint(x: right - r * k, y: 0), control2: CGPoint(x: right, y: r * k))
        if tail {
            // The tail sweeps out of the bottom-right corner to a point, then curls back into the bottom edge.
            p.addLine(to: CGPoint(x: right, y: h - 17))
            p.addCurve(to: CGPoint(x: w, y: h), control1: CGPoint(x: right, y: h - 4), control2: CGPoint(x: w - 2.5, y: h - 0.5))
            p.addCurve(to: CGPoint(x: right - 9, y: h - 4.5), control1: CGPoint(x: w - 6, y: h + 1), control2: CGPoint(x: right - 4, y: h - 1.5))
            p.addCurve(to: CGPoint(x: right - 19, y: h), control1: CGPoint(x: right - 12.5, y: h - 0.8), control2: CGPoint(x: right - 16, y: h))
        } else {
            p.addLine(to: CGPoint(x: right, y: h - r))
            p.addCurve(to: CGPoint(x: right - r, y: h), control1: CGPoint(x: right, y: h - r * k), control2: CGPoint(x: right - r * k, y: h))
        }
        p.addLine(to: CGPoint(x: r, y: h))
        p.addCurve(to: CGPoint(x: 0, y: h - r), control1: CGPoint(x: r * k, y: h), control2: CGPoint(x: 0, y: h - r * k))
        p.addLine(to: CGPoint(x: 0, y: r))
        p.addCurve(to: CGPoint(x: r, y: 0), control1: CGPoint(x: 0, y: r * k), control2: CGPoint(x: r * k, y: 0))
        p.closeSubpath()
        return p
    }
}

extension View {
    /// iMessage text insets inside a `BubbleShape`, including the space reserved for the tail.
    func bubblePadding(fromUser: Bool) -> some View {
        padding(.vertical, 8)
            .padding(.leading, 13 + (fromUser ? 0 : BubbleShape.tailWidth))
            .padding(.trailing, 13 + (fromUser ? BubbleShape.tailWidth : 0))
    }
}

/// The three bouncing dots shown while the agent is working.
struct TypingIndicator: View {
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 8, height: 8)
                    .phaseAnimator([0.35, 1.0]) { dot, phase in
                        dot.opacity(phase)
                    } animation: { _ in
                        .easeInOut(duration: 0.5).delay(Double(index) * 0.18)
                    }
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(Color.agentBubble, in: Capsule())
        .background(alignment: .bottomLeading) {
            // iMessage's typing bubble trails off in two small circles instead of a pointed tail.
            ZStack(alignment: .bottomLeading) {
                Circle().fill(Color.agentBubble).frame(width: 13, height: 13).offset(x: 1, y: 2)
                Circle().fill(Color.agentBubble).frame(width: 6, height: 6).offset(x: -4, y: 8)
            }
        }
        .padding(.leading, 4)
        .padding(.bottom, 6)
        .accessibilityLabel("Agent is working")
    }
}

extension Color {
    static let userBubble = Color(red: 0, green: 122 / 255, blue: 1)
    #if os(macOS)
    static let avatarBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.95, alpha: 1)
    })
    #else
    static let avatarBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.12, alpha: 1) : UIColor(white: 0.95, alpha: 1)
    })
    #endif
    #if os(macOS)
    static let agentBubble = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    #else
    static let agentBubble = Color(uiColor: .systemGray5)
    #endif
}

enum ChatDate {
    /// Session list time, like Messages: time today, "Yesterday", weekday, or short date.
    static func listLabel(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    /// Centered separator inside a chat: "Today 10:42", "Monday 18:03", …
    static func separatorLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return String(localized: "Today \(time)") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday \(time)") }
        return "\(listLabel(date)) \(time)"
    }
}
